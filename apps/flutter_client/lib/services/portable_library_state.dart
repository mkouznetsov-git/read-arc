import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

import '../models/manifest.dart';
import 'library_storage.dart';
import 'sync/merge.dart';

const portableFormatRelativeLocation = '.readarc/format.json';
const portableStateDirectory = '.readarc/state';
const portableRecoveryDirectory = '.readarc/recovery';

enum PortableLibraryDisposition { empty, currentAccount, recoveryRequired, incomplete, unsupported }

class PortableLibraryInspection {
  const PortableLibraryInspection({required this.disposition, this.accountIds = const <String>[], this.message});

  final PortableLibraryDisposition disposition;
  final List<String> accountIds;
  final String? message;

  bool get hasPortableState => disposition != PortableLibraryDisposition.empty;
}

class PortableStateException implements Exception {
  const PortableStateException(this.message);
  final String message;

  @override
  String toString() => 'PortableStateException: $message';
}

class WrongRecoveryKeyException extends PortableStateException {
  const WrongRecoveryKeyException() : super('Recovery Key неверен или не подходит к этой библиотеке');
}

class PortableStateRecoveryResult {
  const PortableStateRecoveryResult({
    required this.manifest,
    required this.accountId,
    required this.accountEncryptionKey,
    required this.snapshotCount,
  });

  final LibraryManifest manifest;
  final String accountId;
  final String accountEncryptionKey;
  final int snapshotCount;
}

class RecoveryKeyMaterial {
  const RecoveryKeyMaterial({required this.displayKey, required this.keyId});

  final String displayKey;
  final String keyId;
}

class _RecoveryEnvelopeCandidate {
  const _RecoveryEnvelopeCandidate({
    required this.envelope,
    required this.accountId,
    required this.keyId,
    required this.rotationCounter,
    required this.rotationDeviceId,
    required this.generationName,
  });

  final Map<String, dynamic> envelope;
  final String accountId;
  final String keyId;
  final int rotationCounter;
  final String rotationDeviceId;
  final String generationName;
}

/// Encrypted, installation-namespaced portable metadata stored in LibraryRoot.
///
/// This layer deliberately serializes [LibraryManifest.toSyncJson] and delegates
/// all conflict decisions to [mergeManifests]. Local paths, security-scoped
/// bookmark bytes, SAF URIs and private keys never enter portable payloads.
class PortableLibraryState {
  PortableLibraryState(this._provider, {Random? random}) : _random = random ?? Random.secure();

  static const formatVersion = 1;
  static const snapshotDomain = 'readarc-portable-state-v1';
  static const recoveryDomain = 'readarc-recovery-envelope-v1';
  static const algorithm = 'AES-256-GCM';
  static const derivation = 'HKDF-SHA256';
  static const _recoveryPrefix = 'RA1';
  static const _base32Alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  final LibraryStorageProvider _provider;
  final Random _random;
  final AesGcm _aes = AesGcm.with256bits();

  Future<PortableLibraryInspection> inspect(LibraryRoot root, {String? currentAccountId}) async {
    final rawFormat = await _provider.readServiceFile(root, portableFormatRelativeLocation);
    final stateFiles = await _provider.listServiceFiles(root, portableStateDirectory);
    final recoveryFiles = await _provider.listServiceFiles(root, portableRecoveryDirectory);
    if (rawFormat == null && stateFiles.isEmpty && recoveryFiles.isEmpty) {
      return const PortableLibraryInspection(disposition: PortableLibraryDisposition.empty);
    }
    if (rawFormat == null) {
      return const PortableLibraryInspection(
        disposition: PortableLibraryDisposition.incomplete,
        message: 'Найден незавершённый каталог .readarc без format.json',
      );
    }

    Map<String, dynamic> format;
    try {
      format = _jsonObject(rawFormat, 'format.json');
    } catch (error) {
      return PortableLibraryInspection(
        disposition: PortableLibraryDisposition.incomplete,
        message: 'format.json повреждён: $error',
      );
    }
    final version = (format['formatVersion'] as num?)?.toInt();
    if (version == null || version > formatVersion) {
      return PortableLibraryInspection(
        disposition: PortableLibraryDisposition.unsupported,
        message: 'Версия portable-state $version не поддерживается',
      );
    }
    if (version != formatVersion || format['format'] != 'readarc-portable-library') {
      return const PortableLibraryInspection(
        disposition: PortableLibraryDisposition.incomplete,
        message: 'Некорректный формат .readarc',
      );
    }

    final accountIds = <String>{};
    for (final path in <String>[...stateFiles, ...recoveryFiles]) {
      final raw = await _provider.readServiceFile(root, path);
      if (raw == null) continue;
      try {
        final header = _jsonObject(raw, path);
        final accountId = header['accountId']?.toString().trim() ?? '';
        if (accountId.isNotEmpty) accountIds.add(accountId);
      } catch (_) {
        // Corrupt generations are reported during authenticated recovery.
      }
    }
    final sorted = accountIds.toList()..sort();
    if (sorted.isEmpty) {
      return const PortableLibraryInspection(
        disposition: PortableLibraryDisposition.incomplete,
        message: 'В .readarc нет читаемых generation headers',
      );
    }
    return PortableLibraryInspection(
      disposition: currentAccountId != null && sorted.length == 1 && sorted.single == currentAccountId
          ? PortableLibraryDisposition.currentAccount
          : PortableLibraryDisposition.recoveryRequired,
      accountIds: sorted,
    );
  }

  Future<bool> hasRecoveryEnvelope(LibraryRoot root, String accountId) async {
    final files = await _provider.listServiceFiles(root, portableRecoveryDirectory);
    for (final path in files) {
      final header = await _readHeader(root, path);
      if (header?['kind'] == 'recovery-envelope' && header?['accountId'] == accountId) {
        return true;
      }
    }
    return false;
  }

  Future<void> bootstrap(LibraryRoot root, LibraryManifest manifest) async {
    await _ensureFormat(root);
    await writeSnapshot(root, manifest);
  }

  Future<void> writeSnapshot(LibraryRoot root, LibraryManifest manifest) async {
    _validateAccountKey(manifest.accountEncryptionKey);
    await _ensureFormat(root);
    final namespace = _namespace(manifest.deviceId);
    final current = '$portableStateDirectory/$namespace/current';
    final currentHeader = await _readHeader(root, current);
    final previousHeader = await _readHeader(root, current.replaceFirst(RegExp(r'current$'), 'previous'));
    final currentGeneration = (currentHeader?['generation'] as num?)?.toInt() ?? 0;
    final previousGeneration = (previousHeader?['generation'] as num?)?.toInt() ?? 0;
    final generation = (currentGeneration > previousGeneration ? currentGeneration : previousGeneration) + 1;
    final createdAt = DateTime.now().toUtc().toIso8601String();
    final header = <String, dynamic>{
      'formatVersion': formatVersion,
      'kind': 'portable-state',
      'domain': snapshotDomain,
      'algorithm': algorithm,
      'derivation': derivation,
      'accountId': manifest.accountId,
      'originatingDeviceId': manifest.deviceId,
      'generation': generation,
      'revision': manifest.logicalClock,
      'createdAt': createdAt,
    };
    final encrypted = await _encryptJson(
      payload: <String, dynamic>{'manifest': manifest.toSyncJson()},
      inputKey: _decodeBase64Url(manifest.accountEncryptionKey),
      domain: snapshotDomain,
      accountId: manifest.accountId,
      header: header,
    );
    await _provider.publishServiceFile(
      root,
      current,
      Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent(' ').convert(encrypted))),
    );
  }

  Future<LibraryManifest> mergeSnapshots({required LibraryRoot root, required LibraryManifest local}) async {
    final loaded = await _loadSnapshots(
      root: root,
      accountId: local.accountId,
      accountEncryptionKey: local.accountEncryptionKey,
    );
    var merged = local;
    for (final remote in loaded) {
      if (remote.accountId != local.accountId) continue;
      merged = mergeManifests(merged, remote);
    }
    return merged.copyWith(
      accountId: local.accountId,
      accountEncryptionKey: local.accountEncryptionKey,
      deviceId: local.deviceId,
      deviceName: local.deviceName,
      deviceSigningPublicKey: local.deviceSigningPublicKey,
      deviceSigningPrivateKey: local.deviceSigningPrivateKey,
    );
  }

  Future<RecoveryKeyMaterial> createRecoveryKey({required LibraryRoot root, required LibraryManifest manifest}) async {
    final bytes = _randomBytes(32);
    final display = _encodeRecoveryKey(bytes);
    final keyId = _keyId(bytes);
    await _writeRecoveryEnvelope(
      root: root,
      manifest: manifest,
      recoveryKeyBytes: bytes,
      keyId: keyId,
      activation: 'pending',
      rotationCounter: manifest.logicalClock,
    );
    return RecoveryKeyMaterial(displayKey: display, keyId: keyId);
  }

  Future<void> activateRecoveryKey({
    required LibraryRoot root,
    required LibraryManifest manifest,
    required String recoveryKey,
  }) async {
    final keyBytes = _decodeRecoveryKey(recoveryKey);
    final keyId = _keyId(keyBytes);
    final current = '$portableRecoveryDirectory/${_namespace(manifest.deviceId)}/current';
    final raw = await _provider.readServiceFile(root, current);
    if (raw == null) {
      throw const PortableStateException('Pending Recovery Key не найден');
    }
    final envelope = _jsonObject(raw, current);
    final activation = envelope['activation']?.toString();
    if (envelope['kind'] != 'recovery-envelope' ||
        envelope['accountId'] != manifest.accountId ||
        envelope['originatingDeviceId'] != manifest.deviceId ||
        envelope['keyId'] != keyId ||
        (activation != 'pending' && activation != 'active')) {
      throw const PortableStateException('Pending Recovery Key не соответствует текущей installation');
    }
    final rotation = _rotationRevision(envelope);
    final clear = await _decryptJson(envelope: envelope, inputKey: keyBytes, expectedDomain: recoveryDomain);
    if (clear['accountEncryptionKey'] != manifest.accountEncryptionKey) {
      throw const PortableStateException('Pending Recovery Key не прошёл проверку account identity');
    }
    await _writeRecoveryEnvelope(
      root: root,
      manifest: manifest,
      recoveryKeyBytes: keyBytes,
      keyId: keyId,
      activation: 'active',
      rotationCounter: rotation.$1,
    );
    try {
      // A second publish makes both durability generations contain the newly
      // confirmed key, so a successful rotation invalidates its predecessor.
      await _writeRecoveryEnvelope(
        root: root,
        manifest: manifest,
        recoveryKeyBytes: keyBytes,
        keyId: keyId,
        activation: 'active',
        rotationCounter: rotation.$1,
      );
    } catch (_) {
      // The first authenticated active generation is already durable. Losing
      // the redundant copy must not misreport a confirmed, usable key as lost.
    }
  }

  Future<bool> verifyRecoveryKey({
    required LibraryRoot root,
    required String recoveryKey,
    String? expectedAccountId,
    bool includePending = false,
  }) async {
    try {
      final result = await recover(
        root: root,
        recoveryKey: recoveryKey,
        freshInstallation: LibraryManifest(
          accountId: expectedAccountId ?? 'recovery-probe',
          deviceId: 'recovery-probe',
          deviceName: 'Recovery probe',
        ),
        probeOnly: true,
        includePending: includePending,
      );
      return expectedAccountId == null || result.accountId == expectedAccountId;
    } on PortableStateException {
      return false;
    } on SecretBoxAuthenticationError {
      return false;
    } on FormatException {
      return false;
    }
  }

  Future<PortableStateRecoveryResult> recover({
    required LibraryRoot root,
    required String recoveryKey,
    required LibraryManifest freshInstallation,
    bool probeOnly = false,
    bool includePending = false,
  }) async {
    final keyBytes = _decodeRecoveryKey(recoveryKey);
    final requestedKeyId = _keyId(keyBytes);
    final recoveryFiles = await _provider.listServiceFiles(root, portableRecoveryDirectory);
    final namespaces = _generationNamespaces(recoveryFiles, portableRecoveryDirectory);
    if (namespaces.isEmpty) {
      throw const PortableStateException('Recovery envelope не найден; нужен другой trusted device');
    }
    final candidates = await _recoveryEnvelopeCandidates(root, namespaces, includePending: includePending);
    final matchingAccounts =
        candidates
            .where((candidate) => candidate.keyId == requestedKeyId)
            .map((candidate) => candidate.accountId)
            .toSet()
            .toList()
          ..sort();

    Map<String, dynamic>? recovered;
    Object? lastFailure;
    for (final candidateAccountId in matchingAccounts) {
      final accountCandidates = candidates.where((candidate) => candidate.accountId == candidateAccountId).toList()
        ..sort(_compareRecoveryCandidates);
      if (accountCandidates.isEmpty) continue;
      final newest = accountCandidates.last;
      if (newest.keyId != requestedKeyId) {
        // The supplied key belonged to this account, but a causally newer
        // confirmed rotation superseded it.
        continue;
      }
      final newestCandidates =
          accountCandidates
              .where(
                (candidate) =>
                    candidate.keyId == requestedKeyId &&
                    candidate.rotationCounter == newest.rotationCounter &&
                    candidate.rotationDeviceId == newest.rotationDeviceId,
              )
              .toList()
            ..sort((left, right) {
              if (left.generationName == right.generationName) return 0;
              return left.generationName == 'current' ? -1 : 1;
            });
      for (final candidate in newestCandidates) {
        try {
          recovered = await _decryptJson(
            envelope: candidate.envelope,
            inputKey: keyBytes,
            expectedDomain: recoveryDomain,
          );
          recovered['accountId'] = candidate.accountId;
          break;
        } catch (error) {
          lastFailure = error;
        }
      }
      if (recovered != null) break;
    }
    if (recovered == null) {
      if (lastFailure != null) {
        throw PortableStateException('Recovery envelope повреждён или не прошёл authentication: $lastFailure');
      }
      throw const WrongRecoveryKeyException();
    }

    final accountId = recovered['accountId']?.toString().trim() ?? '';
    final accountKey = recovered['accountEncryptionKey']?.toString().trim() ?? '';
    if (accountId.isEmpty) {
      throw const PortableStateException('Recovery envelope не содержит accountId');
    }
    _validateAccountKey(accountKey);
    if (probeOnly) {
      return PortableStateRecoveryResult(
        manifest: freshInstallation,
        accountId: accountId,
        accountEncryptionKey: accountKey,
        snapshotCount: 0,
      );
    }

    final currentTrust = TrustedDeviceRecord(
      deviceId: freshInstallation.deviceId,
      name: freshInstallation.deviceName,
      role: 'owner',
      publicKey: freshInstallation.deviceSigningPublicKey,
      keyFingerprint: _fingerprint(freshInstallation.deviceSigningPublicKey),
    );
    var local = freshInstallation.copyWith(
      accountId: accountId,
      accountEncryptionKey: accountKey,
      books: const [],
      trustedDevices: <TrustedDeviceRecord>[currentTrust],
      logicalClock: 0,
      appliedOperationIds: const [],
    );
    final snapshots = await _loadSnapshots(root: root, accountId: accountId, accountEncryptionKey: accountKey);
    if (snapshots.isEmpty) {
      throw const PortableStateException('Recovery envelope корректен, но ни один portable snapshot не читается');
    }
    for (final remote in snapshots) {
      local = mergeManifests(local, remote);
    }
    final devices = <TrustedDeviceRecord>[...local.trustedDevices];
    final currentIndex = devices.indexWhere((device) => device.deviceId == freshInstallation.deviceId);
    if (currentIndex < 0) {
      devices.add(currentTrust);
    } else {
      devices[currentIndex] = currentTrust;
    }
    local = local.copyWith(
      accountId: accountId,
      accountEncryptionKey: accountKey,
      deviceId: freshInstallation.deviceId,
      deviceName: freshInstallation.deviceName,
      deviceSigningPublicKey: freshInstallation.deviceSigningPublicKey,
      deviceSigningPrivateKey: freshInstallation.deviceSigningPrivateKey,
      trustedDevices: devices,
    );
    return PortableStateRecoveryResult(
      manifest: local,
      accountId: accountId,
      accountEncryptionKey: accountKey,
      snapshotCount: snapshots.length,
    );
  }

  Future<void> _writeRecoveryEnvelope({
    required LibraryRoot root,
    required LibraryManifest manifest,
    required List<int> recoveryKeyBytes,
    required String keyId,
    required String activation,
    required int rotationCounter,
  }) async {
    await _ensureFormat(root);
    _validateAccountKey(manifest.accountEncryptionKey);
    final namespace = _namespace(manifest.deviceId);
    final current = '$portableRecoveryDirectory/$namespace/current';
    final currentHeader = await _readHeader(root, current);
    final previousHeader = await _readHeader(root, current.replaceFirst(RegExp(r'current$'), 'previous'));
    final currentGeneration = (currentHeader?['generation'] as num?)?.toInt() ?? 0;
    final previousGeneration = (previousHeader?['generation'] as num?)?.toInt() ?? 0;
    final generation = (currentGeneration > previousGeneration ? currentGeneration : previousGeneration) + 1;
    final header = <String, dynamic>{
      'formatVersion': formatVersion,
      'kind': 'recovery-envelope',
      'domain': recoveryDomain,
      'algorithm': algorithm,
      'derivation': derivation,
      'accountId': manifest.accountId,
      'originatingDeviceId': manifest.deviceId,
      'keyId': keyId,
      'activation': activation,
      'rotationRevision': <String, dynamic>{'counter': rotationCounter, 'deviceId': manifest.deviceId},
      'generation': generation,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    };
    final encrypted = await _encryptJson(
      payload: <String, dynamic>{'accountEncryptionKey': manifest.accountEncryptionKey},
      inputKey: recoveryKeyBytes,
      domain: recoveryDomain,
      accountId: manifest.accountId,
      header: header,
    );
    final bytes = Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent(' ').convert(encrypted)));
    await _provider.publishServiceFile(root, current, bytes);

    // Authenticated read-after-publish: the key is shown to the user only after
    // the durable current generation can actually unwrap the account key.
    final published = await _provider.readServiceFile(root, current);
    if (published == null) {
      throw const PortableStateException('Recovery envelope исчез после публикации');
    }
    final clear = await _decryptJson(
      envelope: _jsonObject(published, current),
      inputKey: recoveryKeyBytes,
      expectedDomain: recoveryDomain,
    );
    if (clear['accountEncryptionKey'] != manifest.accountEncryptionKey) {
      throw const PortableStateException('Recovery envelope не прошёл read-after-write verification');
    }
  }

  Future<List<_RecoveryEnvelopeCandidate>> _recoveryEnvelopeCandidates(
    LibraryRoot root,
    Set<String> namespaces, {
    required bool includePending,
  }) async {
    final result = <_RecoveryEnvelopeCandidate>[];
    final sortedNamespaces = namespaces.toList()..sort();
    for (final namespace in sortedNamespaces) {
      for (final generationName in const <String>['current', 'previous']) {
        final path = '$portableRecoveryDirectory/$namespace/$generationName';
        final raw = await _provider.readServiceFile(root, path);
        if (raw == null) continue;
        try {
          final envelope = _jsonObject(raw, path);
          if (envelope['kind'] != 'recovery-envelope') continue;
          final accountId = envelope['accountId']?.toString().trim() ?? '';
          final keyId = envelope['keyId']?.toString().trim() ?? '';
          final activation = envelope['activation']?.toString() ?? '';
          if (accountId.isEmpty ||
              keyId.isEmpty ||
              (activation != 'active' && !(includePending && activation == 'pending'))) {
            continue;
          }
          final rotation = _rotationRevision(envelope);
          if (rotation.$2 != envelope['originatingDeviceId']) continue;
          result.add(
            _RecoveryEnvelopeCandidate(
              envelope: envelope,
              accountId: accountId,
              keyId: keyId,
              rotationCounter: rotation.$1,
              rotationDeviceId: rotation.$2,
              generationName: generationName,
            ),
          );
        } catch (_) {
          // A malformed current generation can still fall back to previous.
        }
      }
    }
    return result;
  }

  (int, String) _rotationRevision(Map<String, dynamic> envelope) {
    final raw = envelope['rotationRevision'];
    if (raw is! Map) {
      throw const PortableStateException('Recovery envelope не содержит rotationRevision');
    }
    final revision = Map<String, dynamic>.from(raw);
    final counter = (revision['counter'] as num?)?.toInt();
    final deviceId = revision['deviceId']?.toString().trim() ?? '';
    if (counter == null || counter < 0 || deviceId.isEmpty) {
      throw const PortableStateException('Некорректный recovery rotationRevision');
    }
    return (counter, deviceId);
  }

  int _compareRecoveryCandidates(_RecoveryEnvelopeCandidate left, _RecoveryEnvelopeCandidate right) {
    final counterOrder = left.rotationCounter.compareTo(right.rotationCounter);
    if (counterOrder != 0) return counterOrder;
    final deviceOrder = left.rotationDeviceId.compareTo(right.rotationDeviceId);
    if (deviceOrder != 0) return deviceOrder;
    final generationOrder = ((left.envelope['generation'] as num?)?.toInt() ?? 0).compareTo(
      (right.envelope['generation'] as num?)?.toInt() ?? 0,
    );
    if (generationOrder != 0) return generationOrder;
    if (left.generationName == right.generationName) return 0;
    return left.generationName == 'previous' ? -1 : 1;
  }

  Future<List<LibraryManifest>> _loadSnapshots({
    required LibraryRoot root,
    required String accountId,
    required String accountEncryptionKey,
  }) async {
    _validateAccountKey(accountEncryptionKey);
    final files = await _provider.listServiceFiles(root, portableStateDirectory);
    final namespaces = _generationNamespaces(files, portableStateDirectory);
    final result = <LibraryManifest>[];
    for (final namespace in namespaces) {
      Object? lastFailure;
      var hadCandidate = false;
      LibraryManifest? valid;
      for (final generationName in const <String>['current', 'previous']) {
        final path = '$portableStateDirectory/$namespace/$generationName';
        final raw = await _provider.readServiceFile(root, path);
        if (raw == null) continue;
        hadCandidate = true;
        try {
          final envelope = _jsonObject(raw, path);
          if (envelope['accountId'] != accountId) continue;
          final clear = await _decryptJson(
            envelope: envelope,
            inputKey: _decodeBase64Url(accountEncryptionKey),
            expectedDomain: snapshotDomain,
          );
          final rawManifest = clear['manifest'];
          if (rawManifest is! Map) {
            throw const PortableStateException('Portable snapshot не содержит manifest');
          }
          final decoded = LibraryManifest.fromJson(Map<String, dynamic>.from(rawManifest));
          if (decoded.accountId != accountId) {
            throw const PortableStateException('Authenticated snapshot accountId mismatch');
          }
          if (decoded.deviceId != envelope['originatingDeviceId'] ||
              _namespace(decoded.deviceId) != namespace ||
              decoded.logicalClock != (envelope['revision'] as num?)?.toInt()) {
            throw const PortableStateException('Authenticated snapshot identity/revision mismatch');
          }
          if (decoded.deviceSigningPrivateKey.isNotEmpty || decoded.accountEncryptionKey.isNotEmpty) {
            throw const PortableStateException('Portable snapshot содержит запрещённые secrets');
          }
          valid = decoded;
          break;
        } catch (error) {
          lastFailure = error;
        }
      }
      if (valid != null) {
        result.add(valid);
      } else if (hadCandidate && lastFailure != null) {
        throw PortableStateException('Нет валидной generation в state/$namespace: $lastFailure');
      }
    }
    result.sort((a, b) => a.deviceId.compareTo(b.deviceId));
    return result;
  }

  Future<Map<String, dynamic>> _encryptJson({
    required Map<String, dynamic> payload,
    required List<int> inputKey,
    required String domain,
    required String accountId,
    required Map<String, dynamic> header,
  }) async {
    final wrappingKey = await _deriveKey(inputKey, domain: domain, accountId: accountId);
    final nonce = _randomBytes(12);
    final aad = utf8.encode(_aad(header));
    final box = await _aes.encrypt(
      utf8.encode(jsonEncode(payload)),
      secretKey: SecretKey(wrappingKey),
      nonce: nonce,
      aad: aad,
    );
    return <String, dynamic>{
      ...header,
      'nonce': _base64Url(box.nonce),
      'ciphertext': _base64Url(box.cipherText),
      'mac': _base64Url(box.mac.bytes),
    };
  }

  Future<Map<String, dynamic>> _decryptJson({
    required Map<String, dynamic> envelope,
    required List<int> inputKey,
    required String expectedDomain,
  }) async {
    final version = (envelope['formatVersion'] as num?)?.toInt();
    if (version != formatVersion) {
      throw PortableStateException('Неподдерживаемая generation version $version');
    }
    final domain = envelope['domain']?.toString() ?? '';
    if (domain != expectedDomain) {
      throw const PortableStateException('Portable crypto domain mismatch');
    }
    if (envelope['algorithm'] != algorithm || envelope['derivation'] != derivation) {
      throw const PortableStateException('Неподдерживаемый portable crypto algorithm');
    }
    final accountId = envelope['accountId']?.toString().trim() ?? '';
    if (accountId.isEmpty) {
      throw const PortableStateException('Portable accountId пуст');
    }
    final wrappingKey = await _deriveKey(inputKey, domain: domain, accountId: accountId);
    final clear = await _aes.decrypt(
      SecretBox(
        _decodeBase64Url(envelope['ciphertext']?.toString() ?? ''),
        nonce: _decodeBase64Url(envelope['nonce']?.toString() ?? ''),
        mac: Mac(_decodeBase64Url(envelope['mac']?.toString() ?? '')),
      ),
      secretKey: SecretKey(wrappingKey),
      aad: utf8.encode(_aad(envelope)),
    );
    final decoded = jsonDecode(utf8.decode(clear));
    if (decoded is! Map) {
      throw const PortableStateException('Portable encrypted payload не является JSON object');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<List<int>> _deriveKey(List<int> inputKey, {required String domain, required String accountId}) async {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final key = await hkdf.deriveKey(
      secretKey: SecretKey(inputKey),
      nonce: crypto.sha256.convert(utf8.encode('ReadArc/$accountId')).bytes,
      info: utf8.encode(domain),
    );
    return key.extractBytes();
  }

  String _aad(Map<String, dynamic> source) {
    final keys = <String>[
      'formatVersion',
      'kind',
      'domain',
      'algorithm',
      'derivation',
      'accountId',
      'originatingDeviceId',
      if (source.containsKey('keyId')) 'keyId',
      if (source.containsKey('activation')) 'activation',
      if (source.containsKey('rotationRevision')) 'rotationRevision',
      'generation',
      if (source.containsKey('revision')) 'revision',
      'createdAt',
    ];
    return keys.map((key) => '$key=${jsonEncode(source[key])}').join('\n');
  }

  Future<void> _ensureFormat(LibraryRoot root) async {
    final existing = await _provider.readServiceFile(root, portableFormatRelativeLocation);
    if (existing != null) {
      final decoded = _jsonObject(existing, portableFormatRelativeLocation);
      final version = (decoded['formatVersion'] as num?)?.toInt();
      if (version != formatVersion || decoded['format'] != 'readarc-portable-library') {
        throw PortableStateException('Нельзя перезаписать неизвестный .readarc format version $version');
      }
      return;
    }
    final payload = <String, dynamic>{
      'format': 'readarc-portable-library',
      'formatVersion': formatVersion,
      'stateLayout': 'installation-namespaced-current-previous',
      'crypto': '$algorithm/$derivation',
    };
    try {
      await _provider.publishServiceFile(
        root,
        portableFormatRelativeLocation,
        Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent(' ').convert(payload))),
        preservePrevious: false,
      );
    } catch (_) {
      // Two installations may bootstrap the same shared root concurrently.
      // format.json is immutable, so accept the winner only after validation.
      final raced = await _provider.readServiceFile(root, portableFormatRelativeLocation);
      if (raced == null) rethrow;
      final decoded = _jsonObject(raced, portableFormatRelativeLocation);
      if (decoded['format'] != 'readarc-portable-library' || decoded['formatVersion'] != formatVersion) {
        rethrow;
      }
    }
  }

  Future<Map<String, dynamic>?> _readHeader(LibraryRoot root, String path) async {
    final raw = await _provider.readServiceFile(root, path);
    if (raw == null) return null;
    try {
      return _jsonObject(raw, path);
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> _jsonObject(List<int> bytes, String name) {
    final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    if (decoded is! Map) {
      throw FormatException('$name is not a JSON object');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Set<String> _generationNamespaces(Iterable<String> files, String prefix) {
    final result = <String>{};
    for (final file in files) {
      final segments = file.split('/');
      final prefixSegments = prefix.split('/');
      if (segments.length != prefixSegments.length + 2) continue;
      if (segments.take(prefixSegments.length).join('/') != prefix) continue;
      if (segments.last != 'current' && segments.last != 'previous') continue;
      result.add(segments[segments.length - 2]);
    }
    return result;
  }

  String _namespace(String deviceId) {
    final normalized = deviceId.trim();
    if (normalized.isEmpty || !RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(normalized)) {
      return _base64Url(utf8.encode(normalized));
    }
    return normalized;
  }

  void _validateAccountKey(String raw) {
    final bytes = _decodeBase64Url(raw);
    if (bytes.length != 32) {
      throw const PortableStateException('Некорректный account encryption key');
    }
  }

  List<int> _randomBytes(int length) => List<int>.generate(length, (_) => _random.nextInt(256));

  String _encodeRecoveryKey(List<int> secret) {
    final checksum = crypto.sha256.convert(<int>[...utf8.encode(recoveryDomain), ...secret]).bytes.take(4);
    final encoded = _base32(<int>[...secret, ...checksum]);
    final groups = <String>[];
    for (var offset = 0; offset < encoded.length; offset += 4) {
      groups.add(encoded.substring(offset, min(offset + 4, encoded.length)));
    }
    return '$_recoveryPrefix-${groups.join('-')}';
  }

  List<int> _decodeRecoveryKey(String display) {
    final normalized = display.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (!normalized.startsWith(_recoveryPrefix)) {
      throw const WrongRecoveryKeyException();
    }
    final decoded = _base32Decode(normalized.substring(_recoveryPrefix.length));
    if (decoded.length != 36) throw const WrongRecoveryKeyException();
    final secret = decoded.sublist(0, 32);
    final expected = crypto.sha256.convert(<int>[...utf8.encode(recoveryDomain), ...secret]).bytes.take(4).toList();
    final actual = decoded.sublist(32);
    var difference = 0;
    for (var index = 0; index < expected.length; index++) {
      difference |= expected[index] ^ actual[index];
    }
    if (difference != 0) throw const WrongRecoveryKeyException();
    return secret;
  }

  String _base32(List<int> bytes) {
    var buffer = 0;
    var bits = 0;
    final output = StringBuffer();
    for (final byte in bytes) {
      buffer = (buffer << 8) | byte;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        output.write(_base32Alphabet[(buffer >> bits) & 31]);
      }
    }
    if (bits > 0) output.write(_base32Alphabet[(buffer << (5 - bits)) & 31]);
    return output.toString();
  }

  List<int> _base32Decode(String value) {
    var buffer = 0;
    var bits = 0;
    final output = <int>[];
    for (final character in value.split('')) {
      final index = _base32Alphabet.indexOf(character);
      if (index < 0) throw const WrongRecoveryKeyException();
      buffer = (buffer << 5) | index;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        output.add((buffer >> bits) & 255);
      }
    }
    return output;
  }

  String _keyId(List<int> bytes) => _base64Url(crypto.sha256.convert(bytes).bytes).substring(0, 16);

  String _fingerprint(String publicKey) {
    if (publicKey.trim().isEmpty) return '';
    final value = _base64Url(crypto.sha256.convert(utf8.encode(publicKey.trim())).bytes);
    return '${value.substring(0, 8)}…${value.substring(value.length - 8)}';
  }

  String _base64Url(List<int> bytes) => base64UrlEncode(bytes).replaceAll('=', '');

  List<int> _decodeBase64Url(String raw) {
    final normalized = raw.trim();
    if (normalized.isEmpty) return const <int>[];
    final padded = normalized.padRight(normalized.length + ((4 - normalized.length % 4) % 4), '=');
    try {
      return base64Url.decode(padded);
    } on FormatException {
      throw const PortableStateException('Некорректное base64url поле');
    }
  }
}
