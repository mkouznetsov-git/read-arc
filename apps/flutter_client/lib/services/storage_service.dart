import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:file_picker/file_picker.dart';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/book.dart';
import '../models/manifest.dart';
import '../models/sync_settings.dart';
import '../models/sync_revision.dart';
import 'library_repository.dart';
import 'library_migration.dart';
import 'library_scanner.dart';
import 'library_storage.dart';
import 'portable_library_state.dart';

class StorageService {
  StorageService({
    LibraryRepository? repository,
    LibrarySecretStore? secretStore,
    Future<Directory> Function()? appDirectory,
    LibraryStorageProvider? libraryStorageProvider,
    LibraryRoot? initialLibraryRoot,
  }) : this._(repository, secretStore, appDirectory, libraryStorageProvider, initialLibraryRoot);

  StorageService._(
    this._repositoryOverride,
    this._secretStore,
    this._appDirectoryOverride,
    LibraryStorageProvider? libraryStorageProvider,
    this._initialLibraryRoot,
  ) : _libraryStorageProvider =
          libraryStorageProvider ??
          ((Platform.isAndroid || Platform.isMacOS || Platform.isIOS)
              ? PlatformLibraryStorageProvider()
              : LocalDirectoryLibraryStorageProvider(
                  chooseDirectory: () =>
                      FilePicker.platform.getDirectoryPath(dialogTitle: 'Выберите библиотеку ReadArc'),
                ));

  final _uuid = const Uuid();
  final LibraryRepository? _repositoryOverride;
  final LibrarySecretStore? _secretStore;
  final Future<Directory> Function()? _appDirectoryOverride;
  final LibraryStorageProvider _libraryStorageProvider;
  final LibraryRoot? _initialLibraryRoot;
  LibraryRepository? _repositoryInstance;
  Future<Directory>? _appDirFuture;
  LibraryRoot? _rootCache;
  bool _rootLoaded = false;
  Future<LibraryScanResult?>? _scanFuture;
  late final PortableLibraryState _portableState = PortableLibraryState(_libraryStorageProvider);
  Timer? _portableSnapshotDebounce;
  Future<void> _portableWriteTail = Future<void>.value();
  bool _portableWritesSuppressed = false;
  bool _portableStartupDone = false;

  LibraryRepository get repository =>
      _repositoryOverride ??
      (_repositoryInstance ??= LibraryRepository(
        appDirectory: appDir,
        secretStore: _secretStore ?? PlatformLibrarySecretStore(),
        createInitialManifest: _createInitialManifest,
        normalize: _normalizeManifest,
      ));

  Future<Directory> appDir() => _appDirFuture ??= _resolveAppDir();

  Future<Directory> _resolveAppDir() async {
    final appDirectoryOverride = _appDirectoryOverride;
    if (appDirectoryOverride != null) {
      final directory = await appDirectoryOverride();
      if (!await directory.exists()) await directory.create(recursive: true);
      return directory;
    }
    final repositoryOverride = _repositoryOverride;
    if (repositoryOverride != null) {
      return (await repositoryOverride.manifestFile).parent;
    }
    // Canonical ReadArc data directory. Keep it stable so app updates do not
    // erase an existing development/test library. Resolve/migrate it once per
    // StorageService so parallel cold-start consumers share the same I/O path.
    final documents = await getApplicationDocumentsDirectory();
    final appDirectory = Directory(p.join(documents.path, 'ReadArc'));
    await _restoreAppDataIfPrimaryIsEmpty(appDirectory, documents.path);
    if (!await appDirectory.exists()) {
      await appDirectory.create(recursive: true);
    }
    return appDirectory;
  }

  Future<void> _restoreAppDataIfPrimaryIsEmpty(Directory primary, String documentsPath) async {
    try {
      final primaryManifest = File(p.join(primary.path, 'manifest.json'));
      if (await primaryManifest.exists()) return;

      final candidates = <Directory>[Directory(p.join(documentsPath, 'ReadArc'))];
      try {
        final support = await getApplicationSupportDirectory();
        candidates.addAll([Directory(p.join(support.path, 'ReadArc'))]);
      } catch (_) {
        // Some platforms may not expose an application support directory.
      }

      for (final candidate in candidates) {
        if (candidate.path == primary.path) continue;
        final manifest = File(p.join(candidate.path, 'manifest.json'));
        if (!await manifest.exists()) continue;
        await primary.create(recursive: true);
        await _copyDirectoryContents(candidate, primary);
        return;
      }
    } catch (_) {
      // Never block startup because best-effort migration failed.
    }
  }

  Future<void> _copyDirectoryContents(Directory source, Directory target) async {
    if (!await source.exists()) return;
    if (!await target.exists()) await target.create(recursive: true);
    await for (final entity in source.list(recursive: false, followLinks: false)) {
      final destinationPath = p.join(target.path, p.basename(entity.path));
      if (entity is Directory) {
        await _copyDirectoryContents(entity, Directory(destinationPath));
      } else if (entity is File) {
        final destination = File(destinationPath);
        if (!await destination.parent.exists()) await destination.parent.create(recursive: true);
        if (!await destination.exists()) {
          await entity.copy(destination.path);
        }
      }
    }
  }

  /// Legacy migration source only. New imports and transfers must never write
  /// here; canonical source books live under the configured [LibraryRoot].
  @Deprecated('Use importIntoLibrary or commitReceivedBook')
  Future<Directory> booksDir() async {
    final dir = Directory(p.join((await appDir()).path, 'books'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<Directory> processedArtifactsDir() async {
    final dir = Directory(p.join((await appDir()).path, 'processed_artifacts'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<Directory> processedArtifactDir(String bookId) async {
    final safeBookId = bookId.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    final dir = Directory(p.join((await processedArtifactsDir()).path, safeBookId));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> processedArtifactManifestFile(String bookId) async {
    return File(p.join((await processedArtifactDir(bookId)).path, 'artifact.json'));
  }

  Future<File> manifestFile() async {
    return File(p.join((await appDir()).path, 'manifest.json'));
  }

  Future<File> syncSettingsFile() async {
    return File(p.join((await appDir()).path, 'sync_settings.json'));
  }

  Future<File> _libraryRootFile() async => File(p.join((await appDir()).path, 'library_root.json'));

  Future<File> _libraryIndexFile() async => File(p.join((await appDir()).path, 'library_index.json'));

  Future<File> _libraryMigrationFile() async => File(p.join((await appDir()).path, 'library_migration.json'));

  Future<Directory> _materializedBooksDir() async {
    final directory = Directory(p.join((await appDir()).path, 'materialized_books'));
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  Future<LibraryRoot?> configuredLibraryRoot() async {
    if (_rootLoaded) return _rootCache;
    if (_initialLibraryRoot != null) {
      _rootLoaded = true;
      return _rootCache = _initialLibraryRoot;
    }
    final file = await _libraryRootFile();
    for (final candidate in [file, File('${file.path}.previous')]) {
      if (!await candidate.exists()) continue;
      try {
        final decoded = jsonDecode(await candidate.readAsString());
        if (decoded is Map) {
          _rootLoaded = true;
          return _rootCache = LibraryRoot.fromJson(Map<String, dynamic>.from(decoded));
        }
      } catch (_) {
        // Try the previous atomic generation before reporting permission loss.
      }
    }
    if (!await file.exists() && !await File('${file.path}.previous').exists()) {
      _rootLoaded = true;
      return null;
    }
    throw const LibraryRootAccessException(
      LibraryRootStatus.permissionLost,
      'Сохранённое разрешение библиотеки повреждено. Выберите библиотеку заново.',
    );
  }

  Future<LibraryRootStatus?> libraryRootStatus() async {
    var root = await configuredLibraryRoot();
    if (root == null) return null;
    try {
      final refreshed = await _libraryStorageProvider.refreshRoot(root);
      if (refreshed.kind != root.kind ||
          refreshed.locator != root.locator ||
          refreshed.displayName != root.displayName) {
        await _persistLibraryRoot(refreshed);
        _rootCache = refreshed;
        _rootLoaded = true;
        root = refreshed;
      }
      return await _libraryStorageProvider.status(root);
    } on LibraryRootAccessException catch (error) {
      return error.status;
    }
  }

  Future<bool> hasLegacyInternalBooks() async {
    final manifest = await loadManifest();
    for (final book in manifest.books) {
      final localPath = book.localPath;
      if (localPath != null && localPath.isNotEmpty && await File(localPath).exists()) return true;
    }
    return false;
  }

  Future<LibraryRoot?> chooseLibraryRootCandidate() => _libraryStorageProvider.chooseRoot();

  Future<PortableLibraryInspection> inspectPortableLibrary(LibraryRoot root) async {
    final manifest = await loadManifest();
    return _portableState.inspect(root, currentAccountId: manifest.accountId);
  }

  Future<LibraryRoot?> chooseAndConfigureLibrary() async {
    final selected = await chooseLibraryRootCandidate();
    if (selected == null) return null;
    await configureLibraryRoot(selected);
    return selected;
  }

  Future<bool> resumePendingLibraryMigration() async {
    final rootFile = await _libraryRootFile();
    if (await rootFile.exists() || await File('${rootFile.path}.previous').exists()) return false;
    final journal = await _libraryMigrationFile();
    for (final candidate in [journal, File('${journal.path}.previous')]) {
      if (!await candidate.exists()) continue;
      try {
        final decoded = jsonDecode(await candidate.readAsString());
        if (decoded is! Map || decoded['target'] is! Map) continue;
        final pending = LibraryRoot.fromJson(Map<String, dynamic>.from(decoded['target'] as Map));
        try {
          await configureLibraryRoot(pending);
          return true;
        } on LibraryRootAccessException {
          _rootCache = null;
          _rootLoaded = false;
          return false;
        }
      } catch (_) {
        continue;
      }
    }
    return false;
  }

  Future<void> configureLibraryRoot(LibraryRoot root, {bool bootstrapPortableState = true}) async {
    final previousSuppression = _portableWritesSuppressed;
    _portableWritesSuppressed = !bootstrapPortableState;
    var configured = false;
    try {
      root = await _libraryStorageProvider.refreshRoot(root);
      final status = await _libraryStorageProvider.status(root);
      if (status != LibraryRootStatus.available) {
        throw LibraryRootAccessException(status, 'Выбранная библиотека недоступна');
      }
      final manifest = await loadManifest();
      final migrator = LegacyLibraryMigrator(provider: _libraryStorageProvider, journalFile: _libraryMigrationFile);
      await migrator.migrate(target: root, books: manifest.books);

      // The root becomes canonical only after every legacy source has been
      // copied and hash-verified. Source files are intentionally retained.
      await _persistLibraryRoot(root);
      _rootCache = root;
      _rootLoaded = true;
      await refreshLibrary(afterPending: true);
      if (bootstrapPortableState) await flushPortableState();
      configured = true;
    } finally {
      if (!configured) {
        _portableWritesSuppressed = previousSuppression;
      }
      if (!bootstrapPortableState) {
        _portableSnapshotDebounce?.cancel();
        _portableSnapshotDebounce = null;
      }
    }
  }

  Future<void> _persistLibraryRoot(LibraryRoot root) async {
    final file = await _libraryRootFile();
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(const JsonEncoder.withIndent('  ').convert(root.toJson()), flush: true);
    final previous = File('${file.path}.previous');
    if (await previous.exists()) await previous.delete();
    if (await file.exists()) await file.rename(previous.path);
    await temporary.rename(file.path);
    if (await previous.exists()) await previous.delete();
  }

  Future<LibraryScanResult?> refreshLibrary({bool afterPending = false}) async {
    final pending = _scanFuture;
    if (afterPending && pending != null) await pending;
    return _scanFuture ??= _refreshLibrary().whenComplete(() => _scanFuture = null);
  }

  Future<LibraryScanResult?> _refreshLibrary() async {
    final rootStatus = await libraryRootStatus();
    if (rootStatus != null && rootStatus != LibraryRootStatus.available) {
      throw LibraryRootAccessException(rootStatus, 'Library root is not available');
    }
    final root = await configuredLibraryRoot();
    if (root == null) return null;
    final manifest = await loadManifest();
    final indexStore = LibraryIndexStore(_libraryIndexFile);
    final previousIndex = await indexStore.read();
    final result = await LibraryScanner(_libraryStorageProvider)
        .scan(root: root, previousIndex: previousIndex, previousBooks: manifest.books, deviceId: manifest.deviceId);
    await mutateManifest((current) {
      var clock = current.logicalClock;
      final currentById = {for (final book in current.books) book.id: book};
      final scannedById = {for (final book in result.books) book.id: book};
      final reconciled = <BookRecord>[];
      var changed = false;
      for (final scanned in result.books) {
        final previous = currentById[scanned.id];
        final hasSource = scanned.hasLocalSource;
        final availableOn = <String>{...?previous?.availableOnDeviceIds};
        if (hasSource) {
          availableOn.add(current.deviceId);
        } else {
          availableOn.remove(current.deviceId);
        }
        final sortedAvailableOn = availableOn.toList()..sort();
        final merged = previous == null
            ? scanned.copyWith(availableOnDeviceIds: sortedAvailableOn)
            : previous.copyWith(
                fileName: hasSource ? scanned.fileName : previous.fileName,
                format: hasSource ? scanned.format : previous.format,
                sizeBytes: hasSource ? scanned.sizeBytes : previous.sizeBytes,
                contentSha256: scanned.contentSha256,
                clearLocalPath: true,
                relativeLocation: scanned.relativeLocation,
                clearRelativeLocation: !hasSource,
                sourceAvailability: scanned.sourceAvailability,
                clearDeletedAt: hasSource && !previous.isDeleted,
                availableOnDeviceIds: sortedAvailableOn,
                updatedAt: previous.updatedAt,
              );
        final availabilityChanged =
            previous == null ||
            previous.isDeleted != merged.isDeleted ||
            !_sameStrings(previous.availableOnDeviceIds, merged.availableOnDeviceIds);
        if (previous == null || !_sameLocalBookState(previous, merged)) changed = true;
        if (availabilityChanged) {
          clock += 1;
          reconciled.add(
            merged.copyWith(
              metadataRevision: SyncRevision(counter: clock, deviceId: current.deviceId),
              updatedByDeviceId: current.deviceId,
              updatedAt: DateTime.now().toUtc(),
              tombstoneAckedByDeviceIds: const [],
            ),
          );
        } else {
          reconciled.add(merged);
        }
      }
      for (final book in current.books) {
        if (!scannedById.containsKey(book.id)) reconciled.add(book);
      }
      if (!changed) return current;
      return current.copyWith(books: reconciled, logicalClock: clock);
    });
    await indexStore.write(result.index);
    return result;
  }

  Future<File> materializeBook(BookRecord book) async {
    final legacyPath = book.localPath;
    if ((book.relativeLocation == null || book.relativeLocation!.isEmpty) && legacyPath != null) {
      final legacy = File(legacyPath);
      if (await legacy.exists()) return legacy;
    }
    final rootStatus = await libraryRootStatus();
    if (rootStatus != null && rootStatus != LibraryRootStatus.available) {
      throw LibraryRootAccessException(rootStatus, 'Library root is not available');
    }
    final root = await configuredLibraryRoot();
    if (root == null || book.relativeLocation == null) {
      throw const LibraryRootAccessException(LibraryRootStatus.missing, 'Источник книги не настроен');
    }
    final availability = LibraryEntryAvailability.values.firstWhere(
      (candidate) => candidate.name == book.sourceAvailability,
      orElse: () => LibraryEntryAvailability.available,
    );
    final entry = LibraryEntry(
      relativeLocation: book.relativeLocation!,
      sizeBytes: book.sizeBytes,
      availability: availability,
    );
    return _libraryStorageProvider.materialize(root, entry, await _materializedBooksDir());
  }

  Future<String> importIntoLibrary(File source, {required String preferredName, String? expectedSha256}) async {
    final root = await configuredLibraryRoot();
    if (root == null) throw StateError('Сначала выберите корневую папку библиотеки');
    final before = await refreshLibrary(afterPending: true);
    if (expectedSha256 != null) {
      final existing = before?.index.entries
          .where((entry) => entry.contentSha256 == expectedSha256)
          .map((entry) => entry.relativeLocation)
          .firstOrNull;
      if (existing != null) return existing;
    }
    final relative = await _libraryStorageProvider.importFile(root, source, preferredName: preferredName);
    final result = await refreshLibrary(afterPending: true);
    if (expectedSha256 != null &&
        result?.index.entries.any(
              (entry) => entry.relativeLocation == relative && entry.contentSha256 == expectedSha256,
            ) !=
            true) {
      throw const FileSystemException('Imported library copy failed SHA-256 verification');
    }
    return relative;
  }

  Future<LibraryManifest> commitReceivedBook({required BookRecord book, required File verifiedFile}) async {
    final root = await configuredLibraryRoot();
    if (root == null) throw StateError('Сначала выберите корневую папку библиотеки');
    final before = await refreshLibrary(afterPending: true);
    final existing = before?.index.entries.where((entry) => entry.contentSha256 == book.id).firstOrNull;
    if (existing != null) {
      if (await verifiedFile.exists()) await verifiedFile.delete();
      return loadManifest();
    }
    final relative = await _libraryStorageProvider.importFile(root, verifiedFile, preferredName: book.fileName);
    final result = await refreshLibrary(afterPending: true);
    final committed = result?.books.where((item) => item.id == book.id).firstOrNull;
    final verifiedDestination = result?.index.entries.any(
      (entry) => entry.relativeLocation == relative && entry.contentSha256 == book.id,
    );
    if (committed?.relativeLocation == null || verifiedDestination != true) {
      throw const FileSystemException('Полученная книга не появилась в library root');
    }
    if (await verifiedFile.exists()) await verifiedFile.delete();
    return loadManifest();
  }

  bool _sameStrings(List<String> a, List<String> b) => a.length == b.length && a.toSet().containsAll(b);

  bool _sameLocalBookState(BookRecord a, BookRecord b) =>
      a.fileName == b.fileName &&
      a.format == b.format &&
      a.sizeBytes == b.sizeBytes &&
      a.contentSha256 == b.contentSha256 &&
      a.localPath == b.localPath &&
      a.relativeLocation == b.relativeLocation &&
      a.sourceAvailability == b.sourceAvailability &&
      a.isDeleted == b.isDeleted &&
      _sameStrings(a.availableOnDeviceIds, b.availableOnDeviceIds);

  Future<LibraryManifest> _createInitialManifest() async {
    final deviceId = 'device-${_uuid.v4()}';
    final deviceName = _defaultDeviceName();
    final deviceKeyPair = await _newDeviceSigningKeyPair();
    return LibraryManifest(
      accountId: 'account-${_uuid.v4()}',
      accountEncryptionKey: _newAccountEncryptionKey(),
      deviceSigningPublicKey: deviceKeyPair.publicKey,
      deviceSigningPrivateKey: deviceKeyPair.privateKey,
      deviceId: deviceId,
      deviceName: deviceName,
      trustedDevices: [
        TrustedDeviceRecord(
          deviceId: deviceId,
          name: deviceName,
          role: 'owner',
          publicKey: deviceKeyPair.publicKey,
          keyFingerprint: _fingerprint(deviceKeyPair.publicKey),
        ),
      ],
    );
  }

  Future<LibraryManifest> loadManifest() async {
    return repository.mutateAsync((manifest) async {
      final withKey = manifest.accountEncryptionKey.trim().isEmpty
          ? manifest.copyWith(accountEncryptionKey: _newAccountEncryptionKey())
          : manifest;
      final withDeviceKey = await _ensureDeviceSigningKeys(withKey);
      return _ensureCurrentDeviceTrusted(withDeviceKey);
    });
  }

  Future<LibraryManifest> mutateManifest(LibraryManifest Function(LibraryManifest current) update) async {
    final result = await repository.mutate(update);
    _schedulePortableSnapshot(result);
    return result;
  }

  Future<LibraryManifest> replaceManifest(LibraryManifest manifest) async {
    final result = await repository.replace(manifest);
    _schedulePortableSnapshot(result);
    return result;
  }

  void _schedulePortableSnapshot(LibraryManifest manifest) {
    if (_portableWritesSuppressed || !_rootLoaded || _rootCache == null) {
      return;
    }
    _portableSnapshotDebounce?.cancel();
    _portableSnapshotDebounce = Timer(
      const Duration(milliseconds: 750),
      () => unawaited(flushPortableState(manifest: manifest).catchError((_) {})),
    );
  }

  Future<void> flushPortableState({LibraryManifest? manifest}) async {
    if (_portableWritesSuppressed) return;
    _portableSnapshotDebounce?.cancel();
    _portableSnapshotDebounce = null;
    final root = await configuredLibraryRoot();
    if (root == null) return;
    final rootState = await _libraryStorageProvider.status(root);
    if (rootState != LibraryRootStatus.available) {
      throw LibraryRootAccessException(rootState, 'Library root is not available for portable snapshot');
    }
    final snapshot = manifest ?? await repository.read();
    final previous = _portableWriteTail;
    final operation = () async {
      try {
        await previous;
      } catch (_) {
        // A failed provider write must not poison all later checkpoints.
      }
      await _portableState.bootstrap(root, snapshot);
    }();
    _portableWriteTail = operation.catchError((_) {});
    await operation;
  }

  Future<bool> ensurePortableStateOnStartup() async {
    if (_portableStartupDone) return false;
    final root = await configuredLibraryRoot();
    if (root == null) return false;
    final local = await loadManifest();
    final inspection = await _portableState.inspect(root, currentAccountId: local.accountId);
    if (inspection.disposition == PortableLibraryDisposition.empty) {
      await _portableState.bootstrap(root, local);
    } else if (inspection.disposition == PortableLibraryDisposition.currentAccount) {
      final merged = await _portableState.mergeSnapshots(root: root, local: local);
      await repository.replace(merged);
      await refreshLibrary(afterPending: true);
    } else if (inspection.disposition == PortableLibraryDisposition.incomplete ||
        inspection.disposition == PortableLibraryDisposition.unsupported) {
      throw PortableStateException(inspection.message ?? 'Portable state повреждён');
    } else {
      return false;
    }
    _portableStartupDone = true;
    return !await _portableState.hasRecoveryEnvelope(root, local.accountId);
  }

  Future<RecoveryKeyMaterial> createRecoveryKey() async {
    if (_portableWritesSuppressed) {
      throw StateError('Сначала завершите восстановление аккаунта или явно создайте новый аккаунт');
    }
    final root = await configuredLibraryRoot();
    if (root == null) {
      throw StateError('Сначала выберите библиотеку ReadArc');
    }
    final merged = await _portableState.mergeSnapshots(root: root, local: await loadManifest());
    await repository.replace(merged);
    final manifest = await mutateManifest((current) => current.copyWith(logicalClock: current.logicalClock + 1));
    await flushPortableState(manifest: manifest);
    return _portableState.createRecoveryKey(root: root, manifest: manifest);
  }

  Future<void> confirmRecoveryKey(String recoveryKey) async {
    final root = await configuredLibraryRoot();
    if (root == null) {
      throw StateError('Сначала выберите библиотеку ReadArc');
    }
    await _portableState.activateRecoveryKey(root: root, manifest: await loadManifest(), recoveryKey: recoveryKey);
  }

  Future<bool> verifyRecoveryKey(String recoveryKey, {bool includePending = false}) async {
    final root = await configuredLibraryRoot();
    if (root == null) return false;
    final manifest = await loadManifest();
    return _portableState.verifyRecoveryKey(
      root: root,
      recoveryKey: recoveryKey,
      expectedAccountId: manifest.accountId,
      includePending: includePending,
    );
  }

  Future<LibraryManifest> recoverWithRecoveryKey(String recoveryKey) async {
    final root = await configuredLibraryRoot();
    if (root == null) {
      throw StateError('Сначала выберите прежнюю библиотеку ReadArc');
    }
    final freshInstallation = await loadManifest();
    final recovered = await _portableState.recover(
      root: root,
      recoveryKey: recoveryKey,
      freshInstallation: freshInstallation,
    );
    await repository.replaceAfterAuthenticatedRecovery(recovered.manifest);
    await refreshLibrary(afterPending: true);
    final reconciled = await loadManifest();
    _portableWritesSuppressed = false;
    await flushPortableState(manifest: reconciled);
    return reconciled;
  }

  Future<LibraryManifest> recoverPortableStateAfterPairing() async {
    final root = await configuredLibraryRoot();
    final local = await loadManifest();
    if (root == null) {
      _portableWritesSuppressed = false;
      return local;
    }
    final inspection = await _portableState.inspect(root, currentAccountId: local.accountId);
    if (inspection.disposition == PortableLibraryDisposition.currentAccount) {
      final merged = await _portableState.mergeSnapshots(root: root, local: local);
      await repository.replace(merged);
    } else if (inspection.disposition != PortableLibraryDisposition.empty) {
      // The selected root belongs to another account (or is damaged/future
      // format). Pairing authorizes the claimed account, not destruction of the
      // previous account's portable generations. Keep writes suppressed while
      // still indexing physical source files for the claimed account.
      await refreshLibrary(afterPending: true);
      return loadManifest();
    }
    await refreshLibrary(afterPending: true);
    final reconciled = await loadManifest();
    _portableWritesSuppressed = false;
    await flushPortableState(manifest: reconciled);
    return reconciled;
  }

  Future<void> startNewAccountForPortableLibrary() async {
    _portableWritesSuppressed = false;
    await flushPortableState();
  }

  Future<void> dispose() async {
    _portableSnapshotDebounce?.cancel();
    _portableSnapshotDebounce = null;
    await flushPortableState();
  }

  Future<SyncSettings> loadSyncSettings() async {
    final file = await syncSettingsFile();
    if (!await file.exists()) return const SyncSettings();
    final raw = await file.readAsString();
    return SyncSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> saveSyncSettings(SyncSettings settings) async {
    final file = await syncSettingsFile();
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(encoder.convert(settings.toJson()), flush: true);
  }

  Future<LibraryManifest> changeAccountId(String accountId) async {
    final normalized = accountId.trim();
    if (normalized.isEmpty) {
      throw ArgumentError('accountId не может быть пустым');
    }
    return mutateManifest((manifest) => manifest.copyWith(accountId: normalized));
  }

  Future<LibraryManifest> changeDeviceName(String deviceName) async {
    final normalized = deviceName.trim();
    if (normalized.isEmpty) {
      throw ArgumentError('Название устройства не может быть пустым');
    }
    return mutateManifest((manifest) {
      final devices = manifest.trustedDevices.map((device) {
        if (device.deviceId != manifest.deviceId) return device;
        return device.copyWith(
          name: normalized,
          publicKey: manifest.deviceSigningPublicKey,
          keyFingerprint: _fingerprint(manifest.deviceSigningPublicKey),
          lastSeenAt: DateTime.now().toUtc(),
        );
      }).toList();
      return manifest.copyWith(deviceName: normalized, trustedDevices: devices);
    });
  }

  Future<LibraryManifest> trustDevice({
    required String deviceId,
    required String name,
    String role = 'device',
    String publicKey = '',
  }) async {
    final normalizedId = deviceId.trim();
    final normalizedName = name.trim().isEmpty ? 'Устройство' : name.trim();
    final normalizedPublicKey = publicKey.trim();
    if (normalizedId.isEmpty) {
      throw ArgumentError('deviceId не может быть пустым');
    }
    return mutateManifest((manifest) {
      final devices = [...manifest.trustedDevices];
      final index = devices.indexWhere((d) => d.deviceId == normalizedId);
      if (index >= 0) {
        final existing = devices[index];
        devices[index] = existing.copyWith(
          name: normalizedName,
          role: existing.role == 'owner' ? 'owner' : role,
          publicKey: normalizedPublicKey.isEmpty ? existing.publicKey : normalizedPublicKey,
          keyFingerprint: normalizedPublicKey.isEmpty ? existing.keyFingerprint : _fingerprint(normalizedPublicKey),
          lastSeenAt: DateTime.now().toUtc(),
          clearRevocation: true,
        );
      } else {
        devices.add(
          TrustedDeviceRecord(
            deviceId: normalizedId,
            name: normalizedName,
            role: role,
            publicKey: normalizedPublicKey,
            keyFingerprint: _fingerprint(normalizedPublicKey),
          ),
        );
      }
      return manifest.copyWith(trustedDevices: devices);
    });
  }

  Future<LibraryManifest> replaceAccountFromPairing({
    required String accountId,
    required String accountEncryptionKey,
    required String ownerDeviceId,
    required String ownerDeviceName,
    String ownerDevicePublicKey = '',
  }) async {
    final current = await loadManifest();
    final normalizedAccountId = accountId.trim();
    final normalizedAccountKey = accountEncryptionKey.trim();
    final normalizedOwnerDeviceId = ownerDeviceId.trim();
    if (normalizedAccountId.isEmpty || normalizedAccountKey.isEmpty || normalizedOwnerDeviceId.isEmpty) {
      throw ArgumentError('Pairing account identity is incomplete');
    }
    if (current.accountId != normalizedAccountId) {
      // Pairing is an authenticated account boundary. Preserve only the
      // installation identity; books, trust records, Lamport clock and applied
      // operation ids belong to the previous account and must not leak across.
      _portableSnapshotDebounce?.cancel();
      _portableSnapshotDebounce = null;
      _portableWritesSuppressed = await configuredLibraryRoot() != null;
      final owner = TrustedDeviceRecord(
        deviceId: normalizedOwnerDeviceId,
        name: ownerDeviceName.trim().isEmpty ? 'Устройство' : ownerDeviceName.trim(),
        role: 'owner',
        publicKey: ownerDevicePublicKey.trim(),
        keyFingerprint: _fingerprint(ownerDevicePublicKey.trim()),
      );
      final self = TrustedDeviceRecord(
        deviceId: current.deviceId,
        name: current.deviceName,
        role: 'device',
        publicKey: current.deviceSigningPublicKey,
        keyFingerprint: _fingerprint(current.deviceSigningPublicKey),
      );
      await repository.replaceAfterAuthenticatedPairing(
        current.copyWith(
          accountId: normalizedAccountId,
          accountEncryptionKey: normalizedAccountKey,
          books: const <BookRecord>[],
          trustedDevices: normalizedOwnerDeviceId == current.deviceId
              ? <TrustedDeviceRecord>[self.copyWith(role: 'owner')]
              : <TrustedDeviceRecord>[owner, self],
          logicalClock: 0,
          appliedOperationIds: const <String>[],
        ),
      );
      await refreshLibrary(afterPending: true);
      return loadManifest();
    }

    await mutateManifest((manifest) => manifest.copyWith(accountEncryptionKey: normalizedAccountKey));
    final withOwner = await trustDevice(
      deviceId: normalizedOwnerDeviceId,
      name: ownerDeviceName,
      role: 'owner',
      publicKey: ownerDevicePublicKey,
    );
    return trustDevice(
      deviceId: withOwner.deviceId,
      name: withOwner.deviceName,
      role: 'device',
      publicKey: withOwner.deviceSigningPublicKey,
    );
  }

  /// Creates a fresh local device identity when this installation was previously
  /// revoked and the user scans a new owner QR code. Reusing the old deviceId
  /// would immediately match the owner's revocation tombstone again, so a
  /// reconnected phone/tablet must come back as a new trusted device. The old
  /// revoked record is preserved for audit/history.
  Future<LibraryManifest> rotateCurrentDeviceIdentityForPairing() async {
    final newKeyPair = await _newDeviceSigningKeyPair();
    return mutateManifest((manifest) {
      if (!manifest.isCurrentDeviceRevoked) return manifest;
      final newDeviceId = 'device-${_uuid.v4()}';
      final now = DateTime.now().toUtc();
      final devices = [
        ...manifest.trustedDevices,
        TrustedDeviceRecord(
          deviceId: newDeviceId,
          name: manifest.deviceName,
          role: 'device',
          publicKey: newKeyPair.publicKey,
          keyFingerprint: _fingerprint(newKeyPair.publicKey),
          addedAt: now,
          lastSeenAt: now,
        ),
      ];

      return manifest.copyWith(
        deviceId: newDeviceId,
        deviceSigningPublicKey: newKeyPair.publicKey,
        deviceSigningPrivateKey: newKeyPair.privateKey,
        trustedDevices: devices,
      );
    });
  }

  Future<LibraryManifest> revokeTrustedDevice(String deviceId, {String reason = 'revoked_by_owner'}) async {
    return mutateManifest((manifest) {
      if (deviceId == manifest.deviceId) throw ArgumentError('Нельзя отозвать доступ у текущего устройства');
      final now = DateTime.now().toUtc();
      final devices = manifest.trustedDevices.map((device) {
        if (device.deviceId != deviceId) return device;
        return device.copyWith(
          deletedAt: now,
          lastSeenAt: now,
          revokedByDeviceId: manifest.deviceId,
          revokedReason: reason,
        );
      }).toList();
      return manifest.copyWith(trustedDevices: devices);
    });
  }

  Future<LibraryManifest> removeTrustedDevice(String deviceId) => revokeTrustedDevice(deviceId);

  Future<LibraryManifest> pruneDeletedTrustedDevices() async {
    return mutateManifest((manifest) {
      final kept = manifest.trustedDevices.where((device) {
        if (device.deviceId == manifest.deviceId) return true;
        return !device.isDeleted;
      }).toList();
      return manifest.copyWith(trustedDevices: kept);
    });
  }

  Future<LibraryManifest> touchCurrentDevice() async {
    return mutateManifest((manifest) {
      final now = DateTime.now().toUtc();
      final devices = manifest.trustedDevices.map((device) {
        if (device.deviceId != manifest.deviceId) return device;
        if (device.isRevoked) return device;
        return device.copyWith(
          name: manifest.deviceName,
          publicKey: manifest.deviceSigningPublicKey,
          keyFingerprint: _fingerprint(manifest.deviceSigningPublicKey),
          lastSeenAt: now,
          clearRevocation: true,
        );
      }).toList();
      return manifest.copyWith(trustedDevices: devices);
    });
  }

  Future<void> upsertBook(BookRecord book) async {
    await mutateManifest((manifest) {
      final revision = _nextRevision(manifest);
      final books = [...manifest.books];
      final index = books.indexWhere((b) => b.id == book.id);
      if (index >= 0) {
        final existing = books[index];
        final availableOn = <String>{...existing.availableOnDeviceIds, ...book.availableOnDeviceIds}.toList()..sort();
        books[index] = existing.copyWith(
          title: book.title,
          fileName: book.fileName,
          format: book.format,
          sizeBytes: book.sizeBytes,
          contentSha256: book.contentSha256,
          localPath: book.localPath,
          relativeLocation: book.relativeLocation,
          sourceAvailability: book.sourceAvailability,
          updatedAt: DateTime.now().toUtc(),
          clearDeletedAt: true,
          availableOnDeviceIds: availableOn,
          metadataRevision: revision,
          tombstoneAckedByDeviceIds: const [],
        );
      } else {
        books.add(
          book.copyWith(
            metadataRevision: revision,
            updatedByDeviceId: manifest.deviceId,
            tombstoneAckedByDeviceIds: const [],
          ),
        );
      }
      return manifest.copyWith(books: books, logicalClock: revision.counter);
    });
  }

  Future<LibraryManifest> updateProgress({
    required String bookId,
    required double progressPercent,
    required String locator,
  }) async {
    return mutateManifest((manifest) {
      final revision = _nextRevision(manifest);
      final updatedBooks = manifest.books.map((book) {
        if (book.id != bookId) return book;
        return book.copyWith(
          progressPercent: progressPercent.clamp(0, 100).toDouble(),
          currentLocator: locator,
          progressVersion: book.progressVersion + 1,
          updatedByDeviceId: manifest.deviceId,
          updatedAt: DateTime.now().toUtc(),
          progressRevision: revision,
        );
      }).toList();
      return manifest.copyWith(books: updatedBooks, logicalClock: revision.counter);
    });
  }

  Future<void> addBookmark({required String bookId, required String label, required String locator}) async {
    await mutateManifest((manifest) {
      final revision = _nextRevision(manifest);
      final updatedBooks = manifest.books.map((book) {
        if (book.id != bookId) return book;
        final bookmark = BookmarkRecord(bookId: bookId, label: label, locator: locator, revision: revision);
        return book.copyWith(bookmarks: [...book.bookmarks, bookmark], updatedAt: DateTime.now().toUtc());
      }).toList();
      return manifest.copyWith(books: updatedBooks, logicalClock: revision.counter);
    });
    await flushPortableState();
  }

  Future<LibraryManifest> removeLocalBookCopy(String bookId) async {
    final manifest = await loadManifest();
    final target = manifest.books.where((book) => book.id == bookId).firstOrNull;
    if (target == null) throw StateError('Книга не найдена в manifest: $bookId');
    await _deleteLocalBookSources(target);
    return mutateManifest((manifest) {
      final revision = _nextRevision(manifest);
      var found = false;
      final updatedBooks = <BookRecord>[];
      for (final book in manifest.books) {
        if (book.id != bookId) {
          updatedBooks.add(book);
          continue;
        }
        found = true;
        final availableOn = book.availableOnDeviceIds.where((deviceId) => deviceId != manifest.deviceId).toList()
          ..sort();
        updatedBooks.add(
          book.copyWith(
            clearLocalPath: true,
            clearRelativeLocation: true,
            sourceAvailability: LibraryEntryAvailability.unavailable.name,
            availableOnDeviceIds: availableOn,
            updatedAt: DateTime.now().toUtc(),
          ),
        );
      }
      if (!found) throw StateError('Книга не найдена в manifest: $bookId');
      final revisedBooks = updatedBooks
          .map((book) => book.id == bookId ? book.copyWith(metadataRevision: revision) : book)
          .toList();
      return manifest.copyWith(books: revisedBooks, logicalClock: revision.counter);
    });
  }

  Future<LibraryManifest> markLocalSourceUnavailable(String bookId) async {
    return mutateManifest((manifest) {
      final revision = _nextRevision(manifest);
      final books = manifest.books.map((book) {
        if (book.id != bookId) return book;
        final availableOn = book.availableOnDeviceIds.where((id) => id != manifest.deviceId).toList()..sort();
        return book.copyWith(
          clearLocalPath: true,
          clearRelativeLocation: true,
          sourceAvailability: LibraryEntryAvailability.unavailable.name,
          availableOnDeviceIds: availableOn,
          metadataRevision: revision,
          updatedAt: DateTime.now().toUtc(),
        );
      }).toList();
      return manifest.copyWith(books: books, logicalClock: revision.counter);
    });
  }

  Future<LibraryManifest> deleteBookFromLibrary(String bookId) async {
    final manifest = await loadManifest();
    final target = manifest.books.where((book) => book.id == bookId).firstOrNull;
    if (target == null) throw StateError('Книга не найдена в manifest: $bookId');
    await _deleteLocalBookSources(target);
    return mutateManifest((manifest) {
      var found = false;
      final now = DateTime.now().toUtc();
      final revision = _nextRevision(manifest);
      final updatedBooks = <BookRecord>[];
      for (final book in manifest.books) {
        if (book.id != bookId) {
          updatedBooks.add(book);
          continue;
        }
        found = true;
        updatedBooks.add(
          book.copyWith(
            clearLocalPath: true,
            clearRelativeLocation: true,
            sourceAvailability: LibraryEntryAvailability.unavailable.name,
            availableOnDeviceIds: const [],
            deletedAt: now,
            updatedAt: now,
            metadataRevision: revision,
            tombstoneAckedByDeviceIds: [manifest.deviceId],
          ),
        );
      }
      if (!found) throw StateError('Книга не найдена в manifest: $bookId');
      return manifest.copyWith(books: updatedBooks, logicalClock: revision.counter);
    });
  }

  Future<LibraryManifest> markBookDownloaded({
    required String bookId,
    String? localPath,
    String? relativeLocation,
  }) async {
    return mutateManifest((manifest) {
      var found = false;
      final revision = _nextRevision(manifest);
      final updatedBooks = manifest.books.map((book) {
        if (book.id != bookId) return book;
        found = true;
        final availableOn = <String>{...book.availableOnDeviceIds, manifest.deviceId}.toList()..sort();
        return book.copyWith(
          localPath: localPath,
          relativeLocation: relativeLocation,
          sourceAvailability: LibraryEntryAvailability.available.name,
          availableOnDeviceIds: availableOn,
          clearDeletedAt: true,
          updatedAt: DateTime.now().toUtc(),
          metadataRevision: revision,
          tombstoneAckedByDeviceIds: const [],
        );
      }).toList();
      if (!found) {
        throw StateError('Книга не найдена в manifest: $bookId');
      }
      return manifest.copyWith(books: updatedBooks, logicalClock: revision.counter);
    });
  }

  SyncRevision _nextRevision(LibraryManifest manifest) =>
      SyncRevision(counter: manifest.logicalClock + 1, deviceId: manifest.deviceId);

  LibraryManifest _normalizeManifest(LibraryManifest manifest) {
    final books = [...manifest.books]
      ..sort((a, b) {
        if (a.isDeleted != b.isDeleted) return a.isDeleted ? 1 : -1;
        return compareBooksForLibrary(a, b);
      });
    final devices = <String, TrustedDeviceRecord>{};
    for (final device in manifest.trustedDevices) {
      final existing = devices[device.deviceId];
      if (existing == null) {
        devices[device.deviceId] = device;
        continue;
      }
      if (existing.isRevoked != device.isRevoked) {
        if (device.isRevoked) devices[device.deviceId] = device;
        continue;
      }
      final existingMarker = existing.deletedAt ?? existing.lastSeenAt;
      final deviceMarker = device.deletedAt ?? device.lastSeenAt;
      if (deviceMarker.isAfter(existingMarker)) devices[device.deviceId] = device;
    }
    final sortedDevices = devices.values.toList()
      ..sort((a, b) {
        if (a.isDeleted != b.isDeleted) return a.isDeleted ? 1 : -1;
        final ownerCompare = (b.role == 'owner' ? 1 : 0).compareTo(a.role == 'owner' ? 1 : 0);
        if (ownerCompare != 0) return ownerCompare;
        final currentCompare = (b.deviceId == manifest.deviceId ? 1 : 0).compareTo(
          a.deviceId == manifest.deviceId ? 1 : 0,
        );
        if (currentCompare != 0) return currentCompare;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return manifest.copyWith(books: books, trustedDevices: sortedDevices);
  }

  Future<void> _deleteLocalBookSources(BookRecord book) async {
    final root = await configuredLibraryRoot();
    if (root != null && book.hasLocalSource) {
      final status = await libraryRootStatus();
      if (status != LibraryRootStatus.available) {
        throw LibraryRootAccessException(
          status ?? LibraryRootStatus.temporarilyUnavailable,
          'Нельзя удалить книгу: корень библиотеки недоступен',
        );
      }
      final before = await refreshLibrary(afterPending: true);
      final locations =
          before?.index.entries
              .where((entry) => entry.contentSha256 == book.id)
              .map((entry) => entry.relativeLocation)
              .toList() ??
          const <String>[];
      for (final relativeLocation in locations) {
        await _libraryStorageProvider.deleteEntry(root, relativeLocation);
      }
      final after = await refreshLibrary(afterPending: true);
      if (after?.index.entries.any((entry) => entry.contentSha256 == book.id) == true) {
        throw const FileSystemException('Не все экземпляры книги удалось удалить из library root');
      }
      return;
    }
    final localPath = book.localPath;
    if (localPath != null && localPath.trim().isNotEmpty) {
      final file = File(localPath);
      if (await file.exists()) await file.delete();
      if (await file.exists()) throw const FileSystemException('Legacy source book could not be deleted');
    }
  }

  LibraryManifest _ensureCurrentDeviceTrusted(LibraryManifest manifest) {
    final devices = [...manifest.trustedDevices];
    final index = devices.indexWhere((d) => d.deviceId == manifest.deviceId);
    if (index >= 0) {
      final current = devices[index];
      // If another trusted owner revoked this device, never silently restore it on
      // startup. The UI can still show local library data, but sync must stop.
      if (current.isRevoked) return manifest;
      final currentKey = manifest.deviceSigningPublicKey;
      if (current.name == manifest.deviceName && current.publicKey == currentKey) return manifest;
      devices[index] = current.copyWith(
        name: manifest.deviceName,
        publicKey: currentKey,
        keyFingerprint: _fingerprint(currentKey),
        lastSeenAt: DateTime.now().toUtc(),
        clearRevocation: true,
      );
      return manifest.copyWith(trustedDevices: devices);
    }
    return manifest.copyWith(
      trustedDevices: [
        ...manifest.trustedDevices,
        TrustedDeviceRecord(
          deviceId: manifest.deviceId,
          name: manifest.deviceName,
          role: manifest.trustedDevices.isEmpty ? 'owner' : 'device',
          publicKey: manifest.deviceSigningPublicKey,
          keyFingerprint: _fingerprint(manifest.deviceSigningPublicKey),
        ),
      ],
    );
  }

  Future<LibraryManifest> _ensureDeviceSigningKeys(LibraryManifest manifest) async {
    if (manifest.deviceSigningPublicKey.trim().isNotEmpty && manifest.deviceSigningPrivateKey.trim().isNotEmpty) {
      return manifest;
    }
    final keyPair = await _newDeviceSigningKeyPair();
    return manifest.copyWith(deviceSigningPublicKey: keyPair.publicKey, deviceSigningPrivateKey: keyPair.privateKey);
  }

  Future<_DeviceSigningKeyPair> _newDeviceSigningKeyPair() async {
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final keyPairData = await keyPair.extract();
    return _DeviceSigningKeyPair(
      publicKey: _base64UrlNoPadding(keyPairData.publicKey.bytes),
      privateKey: _base64UrlNoPadding(keyPairData.bytes),
    );
  }

  String _fingerprint(String publicKey) {
    final normalized = publicKey.trim();
    if (normalized.isEmpty) return '';
    final digest = crypto.sha256.convert(utf8.encode(normalized)).bytes;
    final full = _base64UrlNoPadding(digest);
    return '${full.substring(0, 8)}…${full.substring(full.length - 8)}';
  }

  String _base64UrlNoPadding(List<int> bytes) => base64UrlEncode(bytes).replaceAll('=', '');

  String _newAccountEncryptionKey() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  String _defaultDeviceName() {
    try {
      final host = Platform.localHostname.trim();
      final normalized = host.replaceFirst(RegExp(r'\.local$', caseSensitive: false), '').trim();
      if (normalized.isNotEmpty) return normalized;
    } catch (_) {
      // Some platforms may restrict hostname access.
    }
    return 'Моё устройство';
  }
}

class _DeviceSigningKeyPair {
  const _DeviceSigningKeyPair({required this.publicKey, required this.privateKey});

  final String publicKey;
  final String privateKey;
}
