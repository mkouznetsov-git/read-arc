import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readarc/models/book.dart';
import 'package:readarc/models/manifest.dart';
import 'package:readarc/services/library_repository.dart';
import 'package:readarc/services/library_storage.dart';
import 'package:readarc/services/storage_service.dart';
import 'package:readarc/services/sync/direct_transfer_server.dart';
import 'package:readarc/services/sync/sync_service.dart';

void main() {
  test('two clients exchange progress through a real relay process', () async {
    final root = Directory.current.path.endsWith('apps/flutter_client')
        ? Directory.current.parent.parent.path
        : Directory.current.path;
    final relayDirectory = '$root/server/rendezvous_relay';
    final relayData = await Directory.systemTemp.createTemp('readarc-relay-data-');
    final clientAData = await Directory.systemTemp.createTemp('readarc-client-a-');
    final clientBData = await Directory.systemTemp.createTemp('readarc-client-b-');
    final portProbe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = portProbe.port;
    await portProbe.close();

    final process = await Process.start(
      'python3',
      ['-m', 'uvicorn', 'main:app', '--host', '127.0.0.1', '--port', '$port', '--log-level', 'warning'],
      workingDirectory: relayDirectory,
      environment: {...Platform.environment, 'READARC_RELAY_DATA_DIR': relayData.path},
    );
    final diagnostics = StringBuffer();
    final stdoutSubscription = process.stdout.transform(utf8.decoder).listen(diagnostics.write);
    final stderrSubscription = process.stderr.transform(utf8.decoder).listen(diagnostics.write);

    final key = base64UrlEncode(Uint8List(32)).replaceAll('=', '');
    final secretsA = _MemorySecretStore();
    final secretsB = _MemorySecretStore();
    final storageA = _storage(clientAData, secretsA, _manifest('a', key));
    final storageB = _storage(clientBData, secretsB, _manifest('b', key));
    final syncA = SyncService(storageA);
    final syncB = SyncService(storageB);

    try {
      await _waitForRelay(port, process, diagnostics);
      final relayUrl = 'http://127.0.0.1:$port';
      await syncA.connect(relayUrl: relayUrl);
      await syncB.connect(relayUrl: relayUrl);

      await storageA.updateProgress(bookId: 'book', progressPercent: 67, locator: 'txt:67');
      expect(await syncA.broadcastLibrarySnapshot(reason: 'integration_progress'), isTrue);

      await _waitFor(
        () async => (await storageB.loadManifest()).books.single.progressPercent == 67,
        timeout: const Duration(seconds: 8),
      );
      final received = await storageB.loadManifest();
      expect(received.books.single.progressPercent, 67);
      expect(received.books.single.currentLocator, 'txt:67');
      expect(received.appliedOperationIds, isNotEmpty);
    } finally {
      await syncA.dispose();
      await syncB.dispose();
      process.kill(ProcessSignal.sigterm);
      await process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
      await stdoutSubscription.cancel();
      await stderrSubscription.cancel();
      for (final directory in [relayData, clientAData, clientBData]) {
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('relay file transfer resumes after client crash and verifies SHA-256', () async {
    const chunkSize = 256 * 1024;
    final root = Directory.current.path.endsWith('apps/flutter_client')
        ? Directory.current.parent.parent.path
        : Directory.current.path;
    final relayDirectory = '$root/server/rendezvous_relay';
    final relayData = await Directory.systemTemp.createTemp('readarc-relay-transfer-');
    final clientAData = await Directory.systemTemp.createTemp('readarc-transfer-a-');
    final clientBData = await Directory.systemTemp.createTemp('readarc-transfer-b-');
    final portProbe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = portProbe.port;
    await portProbe.close();
    final process = await Process.start(
      'python3',
      ['-m', 'uvicorn', 'main:app', '--host', '127.0.0.1', '--port', '$port', '--log-level', 'warning'],
      workingDirectory: relayDirectory,
      environment: {...Platform.environment, 'READARC_RELAY_DATA_DIR': relayData.path},
    );
    final diagnostics = StringBuffer();
    final stdoutSubscription = process.stdout.transform(utf8.decoder).listen(diagnostics.write);
    final stderrSubscription = process.stderr.transform(utf8.decoder).listen(diagnostics.write);

    final bytes = List<int>.generate(chunkSize * 3 + 173, (index) => index % 251);
    final hash = sha256.convert(bytes).toString();
    final sourceFile = File('${clientAData.path}/source.txt');
    await sourceFile.writeAsBytes(bytes, flush: true);
    final sourceBook = BookRecord(
      id: hash,
      title: 'Book',
      fileName: 'source.txt',
      format: 'txt',
      sizeBytes: bytes.length,
      contentSha256: hash,
      localPath: sourceFile.path,
      availableOnDeviceIds: const ['a'],
    );
    final remoteBook = sourceBook.copyWith(clearLocalPath: true);
    final key = base64UrlEncode(Uint8List(32)).replaceAll('=', '');
    final secretsA = _MemorySecretStore();
    final secretsB = _MemorySecretStore();
    final storageA = _storage(clientAData, secretsA, _manifest('a', key, book: sourceBook));
    final storageB = _storage(clientBData, secretsB, _manifest('b', key, book: remoteBook));
    final syncA = SyncService(
      storageA,
      directTransferServer: DirectTransferServer(enabled: false),
      fileChunkSize: chunkSize,
      fileChunkAckTimeout: const Duration(seconds: 1),
    );
    var injected = false;
    var syncB = SyncService(
      storageB,
      directTransferServer: DirectTransferServer(enabled: false),
      fileChunkSize: chunkSize,
      pauseAfterCommittedChunk: (checkpoint) {
        if (injected || checkpoint.chunkIndex != 0) return false;
        injected = true;
        return true;
      },
    );

    try {
      await _waitForRelay(port, process, diagnostics);
      final relayUrl = 'http://127.0.0.1:$port';
      await syncA.connect(relayUrl: relayUrl);
      await syncB.connect(relayUrl: relayUrl);
      final requested = (await storageB.loadManifest()).books.single;
      expect(await syncB.requestBookFile(requested), isTrue);

      final partial = File('${clientBData.path}/incoming/$hash.part');
      await _waitFor(
        () async =>
            injected && !syncB.state.value.connected && await partial.exists() && await partial.length() == chunkSize,
        timeout: const Duration(seconds: 8),
      );
      expect((await storageB.loadManifest()).books.single.isDownloaded, isFalse);
      await syncB.dispose();

      syncB = SyncService(
        storageB,
        directTransferServer: DirectTransferServer(enabled: false),
        fileChunkSize: chunkSize,
      );
      await syncB.connect(relayUrl: relayUrl);
      await _waitFor(() async {
        final book = (await storageB.loadManifest()).books.single;
        if (!book.isDownloaded) return false;
        return await (await storageB.materializeBook(book)).exists();
      }, timeout: const Duration(seconds: 15));

      final completed = (await storageB.loadManifest()).books.single;
      final receivedBytes = await (await storageB.materializeBook(completed)).readAsBytes();
      expect(receivedBytes, bytes);
      expect(sha256.convert(receivedBytes).toString(), hash);
      expect(await File('${clientBData.path}/incoming/$hash.transfer.json').exists(), isFalse);
    } finally {
      await syncA.dispose();
      await syncB.dispose();
      process.kill(ProcessSignal.sigterm);
      await process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
      await stdoutSubscription.cancel();
      await stderrSubscription.cancel();
      for (final directory in [relayData, clientAData, clientBData]) {
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    }
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('revoking a device stops its active relay transfer before the next chunk', () async {
    const chunkSize = 256 * 1024;
    final root = Directory.current.path.endsWith('apps/flutter_client')
        ? Directory.current.parent.parent.path
        : Directory.current.path;
    final relayDirectory = '$root/server/rendezvous_relay';
    final relayData = await Directory.systemTemp.createTemp('readarc-relay-revocation-');
    final clientAData = await Directory.systemTemp.createTemp('readarc-revocation-a-');
    final clientBData = await Directory.systemTemp.createTemp('readarc-revocation-b-');
    final portProbe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = portProbe.port;
    await portProbe.close();
    final process = await Process.start(
      'python3',
      ['-m', 'uvicorn', 'main:app', '--host', '127.0.0.1', '--port', '$port', '--log-level', 'warning'],
      workingDirectory: relayDirectory,
      environment: {...Platform.environment, 'READARC_RELAY_DATA_DIR': relayData.path},
    );
    final diagnostics = StringBuffer();
    final stdoutSubscription = process.stdout.transform(utf8.decoder).listen(diagnostics.write);
    final stderrSubscription = process.stderr.transform(utf8.decoder).listen(diagnostics.write);

    final bytes = List<int>.generate(chunkSize * 3, (index) => index % 241);
    final hash = sha256.convert(bytes).toString();
    final sourceFile = File('${clientAData.path}/revoked-source.bin');
    await sourceFile.writeAsBytes(bytes, flush: true);
    final sourceBook = BookRecord(
      id: 'book',
      title: 'Book',
      fileName: 'revoked-source.bin',
      format: 'bin',
      sizeBytes: bytes.length,
      contentSha256: hash,
      localPath: sourceFile.path,
      availableOnDeviceIds: const ['a'],
    );
    final key = base64UrlEncode(Uint8List(32)).replaceAll('=', '');
    final secretsA = _MemorySecretStore();
    final secretsB = _MemorySecretStore();
    final storageA = _storage(clientAData, secretsA, _manifest('a', key, book: sourceBook));
    final storageB = _storage(
      clientBData,
      secretsB,
      _manifest('b', key, book: sourceBook.copyWith(clearLocalPath: true)),
    );
    var revoked = false;
    final syncA = SyncService(
      storageA,
      directTransferServer: DirectTransferServer(enabled: false),
      fileChunkSize: chunkSize,
      beforeSendingFileChunk: (checkpoint) async {
        if (!revoked && checkpoint.chunkIndex == 1) {
          revoked = true;
          await storageA.revokeTrustedDevice('b');
        }
      },
    );
    final syncB = SyncService(
      storageB,
      directTransferServer: DirectTransferServer(enabled: false),
      fileChunkSize: chunkSize,
    );

    try {
      await _waitForRelay(port, process, diagnostics);
      final relayUrl = 'http://127.0.0.1:$port';
      await syncA.connect(relayUrl: relayUrl);
      await syncB.connect(relayUrl: relayUrl);
      expect(await syncB.requestBookFile((await storageB.loadManifest()).books.single), isTrue);

      await _waitFor(
        () async =>
            revoked &&
            syncA.state.value.fileTransfers.values.any(
              (transfer) =>
                  transfer.direction == 'upload' && !transfer.active && transfer.statusText == 'Отправка прервана',
            ),
        timeout: const Duration(seconds: 8),
      );
      final partial = File('${clientBData.path}/incoming/book.part');
      expect(await partial.length(), chunkSize);
      expect((await storageB.loadManifest()).books.single.isDownloaded, isFalse);
      expect(
        (await storageA.loadManifest()).trustedDevices.singleWhere((device) => device.deviceId == 'b').isRevoked,
        isTrue,
      );
    } finally {
      await syncA.dispose();
      await syncB.dispose();
      process.kill(ProcessSignal.sigterm);
      await process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
      await stdoutSubscription.cancel();
      await stderrSubscription.cancel();
      for (final directory in [relayData, clientAData, clientBData]) {
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    }
  }, timeout: const Timeout(Duration(seconds: 30)));
}

StorageService _storage(Directory directory, _MemorySecretStore secrets, LibraryManifest initial) => StorageService(
  repository: LibraryRepository(
    appDirectory: () async => directory,
    secretStore: secrets,
    createInitialManifest: () async => initial,
    normalize: (manifest) => manifest,
  ),
  secretStore: secrets,
  libraryStorageProvider: LocalDirectoryLibraryStorageProvider(),
  initialLibraryRoot: LibraryRoot(
    kind: LibraryRootKind.desktopPath,
    locator: '${directory.path}/user-library',
    displayName: 'Library',
  ),
);

LibraryManifest _manifest(String deviceId, String key, {BookRecord? book}) => LibraryManifest(
  accountId: 'integration-account',
  accountEncryptionKey: key,
  deviceId: deviceId,
  deviceName: deviceId.toUpperCase(),
  deviceSigningPublicKey: 'public-$deviceId',
  deviceSigningPrivateKey: 'private-$deviceId',
  books: [
    book ??
        BookRecord(
          id: 'book',
          title: 'Book',
          fileName: 'book.txt',
          format: 'txt',
          sizeBytes: 1,
          contentSha256: List.filled(64, 'a').join(),
          availableOnDeviceIds: const ['a'],
        ),
  ],
  trustedDevices: [
    TrustedDeviceRecord(deviceId: 'a', name: 'A', role: 'owner', publicKey: 'public-a'),
    TrustedDeviceRecord(deviceId: 'b', name: 'B', publicKey: 'public-b'),
  ],
);

Future<void> _waitForRelay(int port, Process process, StringBuffer diagnostics) async {
  await _waitFor(() async {
    if (await process.exitCode.timeout(Duration.zero, onTimeout: () => -999) != -999) {
      throw StateError('relay exited before startup: $diagnostics');
    }
    final client = HttpClient()..connectionTimeout = const Duration(milliseconds: 250);
    try {
      final request = await client.getUrl(Uri.parse('http://127.0.0.1:$port/health'));
      final response = await request.close().timeout(const Duration(milliseconds: 500));
      await response.drain();
      return response.statusCode == HttpStatus.ok;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }, timeout: const Duration(seconds: 10));
}

Future<void> _waitFor(Future<bool> Function() predicate, {required Duration timeout}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw TimeoutException('condition was not met', timeout);
}

class _MemorySecretStore implements LibrarySecretStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}
