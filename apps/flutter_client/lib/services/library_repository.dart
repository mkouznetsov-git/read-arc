// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/manifest.dart';

abstract interface class LibrarySecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class PlatformLibrarySecretStore implements LibrarySecretStore {
  PlatformLibrarySecretStore([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            // v10 migrates the v9 EncryptedSharedPreferences backend to the
            // authenticated cipher store. Keep a crash-safe backup and never
            // let the plugin erase identity keys on a migration error.
            aOptions: AndroidOptions(resetOnError: false, migrateOnAlgorithmChange: true, migrateWithBackup: true),
            // ReadArc's current macOS artifacts are ad-hoc signed and do not
            // carry a provisioning profile. The Data Protection Keychain
            // requires the Keychain Sharing entitlement, which makes such an
            // app fail to launch on another Mac. The legacy macOS Keychain is
            // still encrypted and avoids that distribution-only entitlement.
            mOptions: MacOsOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
              usesDataProtectionKeychain: false,
            ),
          );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);
}

class ManifestRecoveryException implements IOException {
  ManifestRecoveryException(this.message, [this.cause]);
  final String message;
  final Object? cause;
  @override
  String toString() => 'ManifestRecoveryException: $message${cause == null ? '' : ' ($cause)'}';
}

typedef InitialManifestFactory = Future<LibraryManifest> Function();
typedef ManifestNormalizer = LibraryManifest Function(LibraryManifest manifest);

/// The sole persistence boundary for library metadata.
///
/// Every read/modify/write transaction is serialized. The on-disk format is
/// deliberately isolated here so it can later be replaced by SQLite without
/// changing callers or mutation semantics.
class LibraryRepository {
  LibraryRepository({
    required Future<Directory> Function() appDirectory,
    required LibrarySecretStore secretStore,
    required InitialManifestFactory createInitialManifest,
    required ManifestNormalizer normalize,
    Uuid uuid = const Uuid(),
    this.backupLimit = 5,
  }) : _appDirectory = appDirectory,
       _secretStore = secretStore,
       _createInitialManifest = createInitialManifest,
       _normalize = normalize,
       _uuid = uuid;

  static const accountKeySecret = 'readarc.accountEncryptionKey';
  static const devicePrivateKeySecret = 'readarc.deviceSigningPrivateKey';

  final Future<Directory> Function() _appDirectory;
  final LibrarySecretStore _secretStore;
  final InitialManifestFactory _createInitialManifest;
  final ManifestNormalizer _normalize;
  final Uuid _uuid;
  final int backupLimit;
  Future<void> _tail = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<LibraryManifest> read() => _serialized(_readOrCreate);

  Future<LibraryManifest> mutate(LibraryManifest Function(LibraryManifest current) update) {
    return mutateAsync((current) async => update(current));
  }

  Future<LibraryManifest> mutateAsync(Future<LibraryManifest> Function(LibraryManifest current) update) {
    return _serialized(() async {
      final current = await _readOrCreate();
      final candidate = await update(current);
      if (identical(candidate, current)) return current;
      final updated = _normalize(candidate);
      await _rejectDestructiveReplacement(current, updated);
      await _writeVerified(updated, previous: current);
      return updated;
    });
  }

  Future<LibraryManifest> replace(LibraryManifest replacement) => mutate((_) => replacement);

  /// Commits authenticated account recovery while preserving the installation
  /// identity that was generated in the new sandbox. The ordinary destructive
  /// replacement guard intentionally remains strict for every other caller.
  Future<LibraryManifest> replaceAfterAuthenticatedRecovery(LibraryManifest replacement) => _serialized(() async {
    final current = await _readOrCreate();
    if (replacement.deviceId != current.deviceId ||
        replacement.deviceSigningPublicKey != current.deviceSigningPublicKey ||
        replacement.deviceSigningPrivateKey != current.deviceSigningPrivateKey) {
      throw StateError('Recovery attempted to replace installation device identity');
    }
    if (replacement.accountId.trim().isEmpty || replacement.accountEncryptionKey.trim().isEmpty) {
      throw StateError('Recovered account identity is incomplete');
    }
    final updated = _normalize(replacement);
    await _writeVerified(updated, previous: current);
    return updated;
  });

  Future<File> get manifestFile async => File(p.join((await _appDirectory()).path, 'manifest.json'));

  Future<LibraryManifest> _readOrCreate() async {
    final file = await manifestFile;
    if (!await file.exists()) {
      final recovered = await _recoverFromCandidates(file);
      if (recovered != null) return _hydrateSecrets(recovered);
      final initial = _normalize(await _createInitialManifest());
      await _writeVerified(initial, previous: null);
      return initial;
    }
    try {
      final raw = await file.readAsString();
      final decoded = await _decodeAndMigrate(raw);
      final hydrated = await _hydrateSecrets(decoded);
      if (_storedSchemaVersion(raw) != LibraryManifest.currentSchemaVersion || _containsLegacySecrets(raw)) {
        await _writeVerified(hydrated, previous: decoded);
      }
      return hydrated;
    } catch (error) {
      await _quarantine(file, error);
      final recovered = await _recoverFromCandidates(file);
      if (recovered == null) {
        throw ManifestRecoveryException('manifest.json повреждён, валидная backup-копия не найдена', error);
      }
      final hydrated = await _hydrateSecrets(recovered);
      await _writeVerified(hydrated, previous: null, backupCurrent: false);
      return hydrated;
    }
  }

  bool _containsLegacySecrets(String raw) =>
      raw.contains('"accountEncryptionKey"') || raw.contains('"deviceSigningPrivateKey"');

  int _storedSchemaVersion(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return 0;
    return (decoded['schemaVersion'] as num?)?.toInt() ?? 1;
  }

  Future<LibraryManifest> _decodeAndMigrate(String raw) async {
    if (raw.trim().isEmpty) throw const FormatException('manifest.json is empty');
    final value = jsonDecode(raw);
    if (value is! Map) throw const FormatException('manifest.json root is not an object');
    var json = Map<String, dynamic>.from(value);
    var version = (json['schemaVersion'] as num?)?.toInt() ?? 1;
    if (version > LibraryManifest.currentSchemaVersion) {
      throw FormatException('Unsupported manifest schemaVersion $version');
    }
    if (version < 2) {
      json = await _migrateV1ToV2(json);
      version = 2;
    }
    if (version < 3) json = _migrateV2ToV3(json);
    _validate(json);
    return LibraryManifest.fromJson(json);
  }

  Future<Map<String, dynamic>> _migrateV1ToV2(Map<String, dynamic> source) async {
    final migrated = Map<String, dynamic>.from(source);
    await _persistLegacySecret(migrated, 'accountEncryptionKey', accountKeySecret);
    await _persistLegacySecret(migrated, 'deviceSigningPrivateKey', devicePrivateKeySecret);
    migrated['schemaVersion'] = 2;
    return migrated;
  }

  Map<String, dynamic> _migrateV2ToV3(Map<String, dynamic> source) {
    final migrated = Map<String, dynamic>.from(source);
    final localDeviceId = migrated['deviceId']?.toString() ?? '';
    var clock = (migrated['logicalClock'] as num?)?.toInt() ?? 0;
    final migratedBooks = <Map<String, dynamic>>[];
    for (final rawBook in (migrated['books'] as List?) ?? const []) {
      if (rawBook is! Map) continue;
      final book = Map<String, dynamic>.from(rawBook);
      final updatedBy = book['updatedByDeviceId']?.toString() ?? localDeviceId;
      final progressCounter = (book['progressVersion'] as num?)?.toInt() ?? 0;
      clock = clock < progressCounter ? progressCounter : clock;
      book.putIfAbsent('metadataRevision', () => {'counter': 0, 'deviceId': updatedBy});
      book.putIfAbsent('progressRevision', () => {'counter': progressCounter, 'deviceId': updatedBy});
      clock = _maxRevisionCounter(clock, book['metadataRevision']);
      clock = _maxRevisionCounter(clock, book['progressRevision']);
      book.putIfAbsent(
        'tombstoneAckedByDeviceIds',
        () => book['deletedAt'] == null || localDeviceId.isEmpty ? <String>[] : <String>[localDeviceId],
      );
      final bookmarks = <Map<String, dynamic>>[];
      for (final rawBookmark in (book['bookmarks'] as List?) ?? const []) {
        if (rawBookmark is! Map) continue;
        final bookmark = Map<String, dynamic>.from(rawBookmark);
        bookmark.putIfAbsent('revision', () => {'counter': 0, 'deviceId': updatedBy});
        clock = _maxRevisionCounter(clock, bookmark['revision']);
        bookmark.putIfAbsent(
          'tombstoneAckedByDeviceIds',
          () => bookmark['deletedAt'] == null || localDeviceId.isEmpty ? <String>[] : <String>[localDeviceId],
        );
        bookmarks.add(bookmark);
      }
      book['bookmarks'] = bookmarks;
      migratedBooks.add(book);
    }
    migrated
      ..['books'] = migratedBooks
      ..['logicalClock'] = clock
      ..putIfAbsent('appliedOperationIds', () => <String>[])
      ..['schemaVersion'] = 3;
    return migrated;
  }

  int _maxRevisionCounter(int clock, Object? rawRevision) {
    if (rawRevision is! Map) return clock;
    final counter = (rawRevision['counter'] as num?)?.toInt() ?? 0;
    return counter > clock ? counter : clock;
  }

  Future<void> _persistLegacySecret(Map<String, dynamic> json, String field, String key) async {
    final value = json.remove(field)?.toString().trim() ?? '';
    if (value.isNotEmpty && (await _secretStore.read(key) ?? '').isEmpty) await _secretStore.write(key, value);
  }

  void _validate(Map<String, dynamic> json) {
    if ((json['accountId']?.toString().trim() ?? '').isEmpty) throw const FormatException('accountId is empty');
    if ((json['deviceId']?.toString().trim() ?? '').isEmpty) throw const FormatException('deviceId is empty');
    if (json['books'] is! List) throw const FormatException('books is not a list');
    if (json['trustedDevices'] is! List) throw const FormatException('trustedDevices is not a list');
  }

  Future<LibraryManifest> _hydrateSecrets(LibraryManifest manifest) async => manifest.copyWith(
    accountEncryptionKey: await _secretStore.read(accountKeySecret) ?? manifest.accountEncryptionKey,
    deviceSigningPrivateKey: await _secretStore.read(devicePrivateKeySecret) ?? manifest.deviceSigningPrivateKey,
  );

  Future<void> persistSecrets(LibraryManifest manifest) async {
    if (manifest.accountEncryptionKey.trim().isNotEmpty) {
      await _secretStore.write(accountKeySecret, manifest.accountEncryptionKey.trim());
    }
    if (manifest.deviceSigningPrivateKey.trim().isNotEmpty) {
      await _secretStore.write(devicePrivateKeySecret, manifest.deviceSigningPrivateKey.trim());
    }
  }

  Future<void> _rejectDestructiveReplacement(LibraryManifest current, LibraryManifest candidate) async {
    if (current.visibleBooks.isEmpty || candidate.visibleBooks.isNotEmpty) return;
    if (candidate.books.length >= current.books.length && current.books.isNotEmpty) return;
    final directory = Directory(p.join((await _appDirectory()).path, 'manifest_rejected'));
    await directory.create(recursive: true);
    final stamp = DateTime.now().toUtc().microsecondsSinceEpoch;
    await File(p.join(directory.path, 'destructive_$stamp.json'))
        .writeAsString(const JsonEncoder.withIndent('  ').convert(candidate.toJson()), flush: true);
    throw StateError('Отклонена потенциально разрушительная замена непустой библиотеки пустым manifest');
  }

  Future<void> _writeVerified(
    LibraryManifest manifest, {
    required LibraryManifest? previous,
    bool backupCurrent = true,
  }) async {
    await persistSecrets(manifest);
    final file = await manifestFile;
    await file.parent.create(recursive: true);
    final payload = const JsonEncoder.withIndent('  ')
        .convert(manifest.copyWith(schemaVersion: LibraryManifest.currentSchemaVersion).toJson());
    final temp = File('${file.path}.tmp-${_uuid.v4()}');
    await temp.writeAsString(payload, flush: true);
    await _decodeAndMigrate(await temp.readAsString());
    if (backupCurrent && await file.exists()) await _createBackupFrom(file);
    final previousFile = File('${file.path}.previous');
    try {
      if (await previousFile.exists()) await previousFile.delete();
      if (await file.exists()) await file.rename(previousFile.path);
      await temp.rename(file.path);
      await _decodeAndMigrate(await file.readAsString());
      if (await previousFile.exists()) await previousFile.delete();
    } catch (error) {
      if (!await file.exists() && await previousFile.exists()) await previousFile.rename(file.path);
      rethrow;
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  Future<void> _createBackupFrom(File source) async {
    final decoded = await _decodeAndMigrate(await source.readAsString());
    final directory = Directory(p.join(source.parent.path, 'manifest_backups'));
    await directory.create(recursive: true);
    final stamp = DateTime.now().toUtc().microsecondsSinceEpoch;
    final backup = File(p.join(directory.path, 'manifest_$stamp.json'));
    await backup.writeAsString(const JsonEncoder.withIndent('  ').convert(decoded.toJson()), flush: true);
    await _decodeAndMigrate(await backup.readAsString());
    final backups = await directory.list().where((e) => e is File).cast<File>().toList();
    backups.sort((a, b) => b.path.compareTo(a.path));
    for (final stale in backups.skip(backupLimit)) {
      await stale.delete();
    }
  }

  Future<LibraryManifest?> _recoverFromCandidates(File manifest) async {
    final candidates = <File>[File('${manifest.path}.previous')];
    final backupDir = Directory(p.join(manifest.parent.path, 'manifest_backups'));
    if (await backupDir.exists()) {
      final backups = await backupDir.list().where((e) => e is File).cast<File>().toList();
      backups.sort((a, b) => b.path.compareTo(a.path));
      candidates.addAll(backups);
    }
    for (final candidate in candidates) {
      if (!await candidate.exists()) continue;
      try {
        return await _decodeAndMigrate(await candidate.readAsString());
      } catch (_) {
        // Continue to the next independently verified generation.
      }
    }
    return null;
  }

  Future<void> _quarantine(File file, Object error) async {
    final dir = Directory(p.join(file.parent.path, 'manifest_recovery'));
    await dir.create(recursive: true);
    final stamp = DateTime.now().toUtc().microsecondsSinceEpoch;
    if (await file.exists()) await file.copy(p.join(dir.path, 'broken_manifest_$stamp.json'));
    await File(p.join(dir.path, 'broken_manifest_$stamp.txt')).writeAsString('$error\n', flush: true);
  }
}
