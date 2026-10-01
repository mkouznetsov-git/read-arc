import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readarc/models/book.dart';
import 'package:readarc/models/manifest.dart';
import 'package:readarc/models/sync_revision.dart';
import 'package:readarc/services/library_repository.dart';
import 'package:readarc/services/library_storage.dart';
import 'package:readarc/services/portable_library_state.dart';
import 'package:readarc/services/storage_service.dart';

void main() {
  group('Sprint 49B portable library state', () {
    late Directory temp;
    late Directory root;
    late LocalDirectoryLibraryStorageProvider provider;
    late LibraryRoot libraryRoot;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('readarc-portable-state-');
      root = Directory('${temp.path}/library');
      await root.create();
      provider = LocalDirectoryLibraryStorageProvider();
      libraryRoot = LibraryRoot(kind: LibraryRootKind.desktopPath, locator: root.path, displayName: 'Library');
    });

    tearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    test('snapshot is encrypted, secret-free and uses fresh nonce', () async {
      final portable = PortableLibraryState(provider);
      final manifest = _manifest(deviceId: 'device-a', privateKey: 'PRIVATE-DEVICE-A');
      await portable.writeSnapshot(libraryRoot, manifest);
      final first =
          jsonDecode(await File('${root.path}/.readarc/state/device-a/current').readAsString()) as Map<String, dynamic>;
      await portable.writeSnapshot(libraryRoot, manifest.copyWith(logicalClock: 2));
      final second =
          jsonDecode(await File('${root.path}/.readarc/state/device-a/current').readAsString()) as Map<String, dynamic>;
      final all = await _readReadArc(root);
      expect(all, isNot(contains(manifest.accountEncryptionKey)));
      expect(all, isNot(contains(manifest.deviceSigningPrivateKey)));
      expect(first['ciphertext'], isNotEmpty);
      expect(first['nonce'], isNot(second['nonce']));
      expect(first['generation'], 1);
      expect(second['generation'], 2);
    });

    test('current corruption falls back to previous generation', () async {
      final portable = PortableLibraryState(provider);
      final initial = _manifest(deviceId: 'device-a', progress: 41);
      await portable.writeSnapshot(libraryRoot, initial);
      await portable.writeSnapshot(libraryRoot, initial.copyWith(logicalClock: 9));
      await File('${root.path}/.readarc/state/device-a/current').writeAsString('truncated', flush: true);

      final fresh = _manifest(deviceId: 'device-c', privateKey: 'NEW-PRIVATE', books: const []);
      final merged = await portable.mergeSnapshots(root: libraryRoot, local: fresh);
      expect(merged.books.single.progressPercent, 41);
      expect(merged.deviceId, 'device-c');
      expect(merged.deviceSigningPrivateKey, 'NEW-PRIVATE');
    });

    test('tampered current and previous fail without empty fallback', () async {
      final portable = PortableLibraryState(provider);
      final manifest = _manifest(deviceId: 'device-a');
      await portable.writeSnapshot(libraryRoot, manifest);
      await portable.writeSnapshot(libraryRoot, manifest);
      for (final name in const ['current', 'previous']) {
        final file = File('${root.path}/.readarc/state/device-a/$name');
        final decoded = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final ciphertext = decoded['ciphertext'] as String;
        decoded['ciphertext'] = (ciphertext.startsWith('A') ? 'B' : 'A') + ciphertext.substring(1);
        await file.writeAsString(jsonEncode(decoded), flush: true);
      }
      await expectLater(
        portable.mergeSnapshots(
          root: libraryRoot,
          local: _manifest(deviceId: 'device-c'),
        ),
        throwsA(isA<PortableStateException>()),
      );
    });

    test('two installations never overwrite each namespace', () async {
      final portable = PortableLibraryState(provider);
      await portable.writeSnapshot(libraryRoot, _manifest(deviceId: 'device-a', progress: 10));
      await portable.writeSnapshot(libraryRoot, _manifest(deviceId: 'device-b', progress: 80));
      expect(await File('${root.path}/.readarc/state/device-a/current').exists(), isTrue);
      expect(await File('${root.path}/.readarc/state/device-b/current').exists(), isTrue);
      final merged = await portable.mergeSnapshots(
        root: libraryRoot,
        local: _manifest(deviceId: 'device-c', books: const []),
      );
      expect(merged.books.single.progressPercent, 80);
    });

    test('duplicate snapshot merge is idempotent', () async {
      final portable = PortableLibraryState(provider);
      await portable.writeSnapshot(libraryRoot, _manifest(deviceId: 'device-a', progress: 55));
      final fresh = _manifest(deviceId: 'device-c', books: const []);
      final once = await portable.mergeSnapshots(root: libraryRoot, local: fresh);
      final twice = await portable.mergeSnapshots(root: libraryRoot, local: once);
      expect(twice.books.single.progressPercent, 55);
      expect(twice.books.single.bookmarks.length, 2);
    });

    test('stale portable progress cannot roll back local revision', () async {
      final portable = PortableLibraryState(provider);
      await portable.writeSnapshot(libraryRoot, _manifest(deviceId: 'device-a', progress: 10));
      final base = _manifest(deviceId: 'device-c');
      final localBook = base.books.single.copyWith(
        progressPercent: 91,
        currentLocator: 'epub:new',
        progressRevision: const SyncRevision(counter: 20, deviceId: 'device-c'),
      );
      final merged = await portable.mergeSnapshots(
        root: libraryRoot,
        local: base.copyWith(books: <BookRecord>[localBook], logicalClock: 20),
      );
      expect(merged.books.single.progressPercent, 91);
      expect(merged.books.single.currentLocator, 'epub:new');
    });

    test('interrupted Recovery Key rotation leaves old key valid', () async {
      var fail = false;
      final faulting = LocalDirectoryLibraryStorageProvider(
        afterServiceStaged: (file) async {
          if (fail && file.path.contains('${Platform.pathSeparator}recovery${Platform.pathSeparator}')) {
            throw StateError('simulated rotation interruption');
          }
        },
      );
      final portable = PortableLibraryState(faulting);
      final manifest = _manifest(deviceId: 'device-a');
      await portable.writeSnapshot(libraryRoot, manifest);
      final oldKey = await portable.createRecoveryKey(root: libraryRoot, manifest: manifest);
      await portable.activateRecoveryKey(root: libraryRoot, manifest: manifest, recoveryKey: oldKey.displayKey);
      fail = true;
      await expectLater(portable.createRecoveryKey(root: libraryRoot, manifest: manifest), throwsStateError);
      fail = false;
      expect(
        await portable.verifyRecoveryKey(
          root: libraryRoot,
          recoveryKey: oldKey.displayKey,
          expectedAccountId: manifest.accountId,
        ),
        isTrue,
      );
    });

    test('confirmed Recovery Key rotation revokes old key and pending rotation does not', () async {
      final portable = PortableLibraryState(provider);
      final manifest = _manifest(deviceId: 'device-a');
      await portable.writeSnapshot(libraryRoot, manifest);
      final oldKey = await portable.createRecoveryKey(root: libraryRoot, manifest: manifest);
      await portable.activateRecoveryKey(root: libraryRoot, manifest: manifest, recoveryKey: oldKey.displayKey);

      final rotatedManifest = manifest.copyWith(logicalClock: manifest.logicalClock + 1);
      final newKey = await portable.createRecoveryKey(root: libraryRoot, manifest: rotatedManifest);
      expect(
        await portable.verifyRecoveryKey(
          root: libraryRoot,
          recoveryKey: newKey.displayKey,
          expectedAccountId: manifest.accountId,
        ),
        isFalse,
      );
      expect(
        await portable.verifyRecoveryKey(
          root: libraryRoot,
          recoveryKey: newKey.displayKey,
          expectedAccountId: manifest.accountId,
          includePending: true,
        ),
        isTrue,
      );
      expect(
        await portable.verifyRecoveryKey(
          root: libraryRoot,
          recoveryKey: oldKey.displayKey,
          expectedAccountId: manifest.accountId,
        ),
        isTrue,
      );

      await portable.activateRecoveryKey(root: libraryRoot, manifest: rotatedManifest, recoveryKey: newKey.displayKey);
      expect(
        await portable.verifyRecoveryKey(
          root: libraryRoot,
          recoveryKey: oldKey.displayKey,
          expectedAccountId: manifest.accountId,
        ),
        isFalse,
      );
      expect(
        await portable.verifyRecoveryKey(
          root: libraryRoot,
          recoveryKey: newKey.displayKey,
          expectedAccountId: manifest.accountId,
        ),
        isTrue,
      );
    });

    test('newer rotation wins across installation namespaces', () async {
      final portable = PortableLibraryState(provider);
      final deviceA = _manifest(deviceId: 'device-a');
      final deviceB = _manifest(deviceId: 'device-b').copyWith(logicalClock: deviceA.logicalClock + 1);
      final oldKey = await portable.createRecoveryKey(root: libraryRoot, manifest: deviceA);
      await portable.activateRecoveryKey(root: libraryRoot, manifest: deviceA, recoveryKey: oldKey.displayKey);
      final newKey = await portable.createRecoveryKey(root: libraryRoot, manifest: deviceB);
      await portable.activateRecoveryKey(root: libraryRoot, manifest: deviceB, recoveryKey: newKey.displayKey);

      expect(
        await portable.verifyRecoveryKey(
          root: libraryRoot,
          recoveryKey: oldKey.displayKey,
          expectedAccountId: deviceA.accountId,
        ),
        isFalse,
      );
      expect(
        await portable.verifyRecoveryKey(
          root: libraryRoot,
          recoveryKey: newKey.displayKey,
          expectedAccountId: deviceA.accountId,
        ),
        isTrue,
      );
    });

    test('unauthenticated newer rotation cannot revoke a valid Recovery Key', () async {
      final portable = PortableLibraryState(provider);
      final manifest = _manifest(deviceId: 'device-a');
      await portable.writeSnapshot(libraryRoot, manifest);
      final recovery = await portable.createRecoveryKey(root: libraryRoot, manifest: manifest);
      await portable.activateRecoveryKey(root: libraryRoot, manifest: manifest, recoveryKey: recovery.displayKey);

      final source = File('${root.path}/.readarc/recovery/device-a/current');
      final forged = jsonDecode(await source.readAsString()) as Map<String, dynamic>;
      forged['originatingDeviceId'] = 'attacker-device';
      forged['keyId'] = 'attacker-key';
      forged['rotationRevision'] = <String, dynamic>{'counter': 999999, 'deviceId': 'attacker-device'};
      forged['generation'] = 999999;
      forged.remove('rotationAuth');
      final forgedFile = File('${root.path}/.readarc/recovery/attacker-device/current');
      await forgedFile.parent.create(recursive: true);
      await forgedFile.writeAsString(jsonEncode(forged), flush: true);

      expect(
        await portable.verifyRecoveryKey(
          root: libraryRoot,
          recoveryKey: recovery.displayKey,
          expectedAccountId: manifest.accountId,
        ),
        isTrue,
      );
    });

    test('recovery envelope falls back to previous and rejects double corruption', () async {
      final portable = PortableLibraryState(provider);
      final manifest = _manifest(deviceId: 'device-a');
      await portable.writeSnapshot(libraryRoot, manifest);
      final recovery = await portable.createRecoveryKey(root: libraryRoot, manifest: manifest);
      await portable.activateRecoveryKey(root: libraryRoot, manifest: manifest, recoveryKey: recovery.displayKey);

      for (final name in const <String>['current', 'previous']) {
        final file = File('${root.path}/.readarc/recovery/device-a/$name');
        final decoded = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final ciphertext = decoded['ciphertext'] as String;
        decoded['ciphertext'] = (ciphertext.startsWith('A') ? 'B' : 'A') + ciphertext.substring(1);
        await file.writeAsString(jsonEncode(decoded), flush: true);
        if (name == 'current') {
          expect(
            await portable.verifyRecoveryKey(
              root: libraryRoot,
              recoveryKey: recovery.displayKey,
              expectedAccountId: manifest.accountId,
            ),
            isTrue,
          );
        }
      }

      await expectLater(
        portable.recover(
          root: libraryRoot,
          recoveryKey: recovery.displayKey,
          freshInstallation: _manifest(deviceId: 'fresh-device', books: const []),
        ),
        throwsA(isA<PortableStateException>()),
      );
    });

    test('Recovery Key wraps account key and wrong key is rejected', () async {
      final portable = PortableLibraryState(provider);
      final manifest = _manifest(deviceId: 'device-a');
      await portable.writeSnapshot(libraryRoot, manifest);
      final recovery = await portable.createRecoveryKey(root: libraryRoot, manifest: manifest);
      await portable.activateRecoveryKey(root: libraryRoot, manifest: manifest, recoveryKey: recovery.displayKey);
      final raw = await _readReadArc(root);
      expect(raw, isNot(contains(recovery.displayKey)));
      expect(raw, isNot(contains(manifest.accountEncryptionKey)));
      expect(
        await portable.verifyRecoveryKey(
          root: libraryRoot,
          recoveryKey: recovery.displayKey,
          expectedAccountId: manifest.accountId,
        ),
        isTrue,
      );

      final otherRoot = Directory('${temp.path}/other');
      await otherRoot.create();
      final other = LibraryRoot(kind: LibraryRootKind.desktopPath, locator: otherRoot.path, displayName: 'Other');
      final wrong = await portable.createRecoveryKey(root: other, manifest: manifest);
      await expectLater(
        portable.recover(
          root: libraryRoot,
          recoveryKey: wrong.displayKey,
          freshInstallation: _manifest(deviceId: 'fresh-device', privateKey: 'FRESH-PRIVATE', books: const []),
        ),
        throwsA(isA<WrongRecoveryKeyException>()),
      );
    });

    test('authenticated recovery preserves account but not device identity', () async {
      final portable = PortableLibraryState(provider);
      final old = _manifest(deviceId: 'device-a', privateKey: 'OLD-PRIVATE');
      await portable.writeSnapshot(libraryRoot, old);
      final recovery = await portable.createRecoveryKey(root: libraryRoot, manifest: old);
      await portable.activateRecoveryKey(root: libraryRoot, manifest: old, recoveryKey: recovery.displayKey);
      final fresh = _manifest(deviceId: 'device-new', privateKey: 'NEW-PRIVATE', books: const []);
      final recovered = await portable.recover(
        root: libraryRoot,
        recoveryKey: recovery.displayKey,
        freshInstallation: fresh,
      );
      expect(recovered.accountId, old.accountId);
      expect(recovered.accountEncryptionKey, old.accountEncryptionKey);
      expect(recovered.manifest.deviceId, 'device-new');
      expect(recovered.manifest.deviceSigningPrivateKey, 'NEW-PRIVATE');
      expect(recovered.manifest.deviceSigningPrivateKey, isNot('OLD-PRIVATE'));
      expect(
        recovered.manifest.trustedDevices.map((device) => device.deviceId),
        containsAll(<String>['device-a', 'device-new']),
      );
    });

    test('interrupted publish restores verified current', () async {
      var fail = false;
      final faulting = LocalDirectoryLibraryStorageProvider(
        afterServiceStaged: (_) async {
          if (fail) throw StateError('simulated publish interruption');
        },
      );
      final portable = PortableLibraryState(faulting);
      final first = _manifest(deviceId: 'device-a', progress: 12);
      await portable.writeSnapshot(libraryRoot, first);
      fail = true;
      await expectLater(portable.writeSnapshot(libraryRoot, first.copyWith(logicalClock: 10)), throwsStateError);
      fail = false;
      final merged = await portable.mergeSnapshots(
        root: libraryRoot,
        local: _manifest(deviceId: 'device-c', books: const []),
      );
      expect(merged.books.single.progressPercent, 12);
    });

    test('missing root is not recreated by portable write', () async {
      final portable = PortableLibraryState(provider);
      await root.delete(recursive: true);
      await expectLater(
        portable.writeSnapshot(libraryRoot, _manifest(deviceId: 'device-a')),
        throwsA(isA<LibraryRootAccessException>()),
      );
      expect(await root.exists(), isFalse);
    });

    test('unsupported and incomplete format are explicit states', () async {
      final format = File('${root.path}/.readarc/format.json');
      await format.parent.create(recursive: true);
      await format.writeAsString(
        jsonEncode(<String, dynamic>{'format': 'readarc-portable-library', 'formatVersion': 99}),
      );
      var inspected = await PortableLibraryState(provider).inspect(libraryRoot);
      expect(inspected.disposition, PortableLibraryDisposition.unsupported);

      await format.delete();
      await File('${root.path}/.readarc/state/device-a/current').create(recursive: true);
      inspected = await PortableLibraryState(provider).inspect(libraryRoot);
      expect(inspected.disposition, PortableLibraryDisposition.incomplete);
    });
  });

  test('pairing account identity unlocks portable snapshot merge', () async {
    final temp = await Directory.systemTemp.createTemp('readarc-pairing-recovery-');
    try {
      final root = Directory('${temp.path}/library');
      final sandbox = Directory('${temp.path}/sandbox');
      await root.create();
      final rootHandle = LibraryRoot(kind: LibraryRootKind.desktopPath, locator: root.path, displayName: 'Library');
      final provider = LocalDirectoryLibraryStorageProvider();
      final portable = PortableLibraryState(provider);
      final owner = _manifest(deviceId: 'owner-device', progress: 77);
      await portable.writeSnapshot(rootHandle, owner);

      final storage = StorageService(
        appDirectory: () async => sandbox,
        secretStore: _MemorySecretStore(),
        libraryStorageProvider: provider,
      );
      await storage.configureLibraryRoot(rootHandle, bootstrapPortableState: false);
      final fresh = await storage.loadManifest();
      await storage.replaceAccountFromPairing(
        accountId: owner.accountId,
        accountEncryptionKey: owner.accountEncryptionKey,
        ownerDeviceId: owner.deviceId,
        ownerDeviceName: owner.deviceName,
        ownerDevicePublicKey: owner.deviceSigningPublicKey,
      );
      final recovered = await storage.recoverPortableStateAfterPairing();
      expect(recovered.accountId, owner.accountId);
      expect(recovered.deviceId, fresh.deviceId);
      expect(recovered.deviceSigningPrivateKey, fresh.deviceSigningPrivateKey);
      expect(recovered.books.single.progressPercent, 77);
      await storage.dispose();
    } finally {
      if (await temp.exists()) await temp.delete(recursive: true);
    }
  });

  test('complete sandbox and secure-store loss recovers from LibraryRoot', () async {
    final temp = await Directory.systemTemp.createTemp('readarc-reinstall-recovery-');
    try {
      final root = Directory('${temp.path}/library');
      final sandboxA = Directory('${temp.path}/sandbox-a');
      final sandboxB = Directory('${temp.path}/sandbox-b');
      await root.create();
      final source = File('${root.path}/book.txt');
      await source.writeAsString('portable book identity', flush: true);
      final rootHandle = LibraryRoot(kind: LibraryRootKind.desktopPath, locator: root.path, displayName: 'Library');
      final provider = LocalDirectoryLibraryStorageProvider();
      final storageA = StorageService(
        appDirectory: () async => sandboxA,
        secretStore: _MemorySecretStore(),
        libraryStorageProvider: provider,
      );
      await storageA.configureLibraryRoot(rootHandle);
      var old = await storageA.loadManifest();
      final bookId = sha256.convert(await source.readAsBytes()).toString();
      expect(old.books.single.id, bookId);
      await storageA.updateProgress(bookId: bookId, progressPercent: 63, locator: 'paragraph:42');
      await storageA.addBookmark(bookId: bookId, label: 'keep', locator: 'paragraph:42');
      await storageA.addBookmark(bookId: bookId, label: 'deleted', locator: 'paragraph:7');
      await storageA.mutateManifest((manifest) {
        final revision = SyncRevision(counter: manifest.logicalClock + 1, deviceId: manifest.deviceId);
        final book = manifest.books.single;
        final bookmarks = book.bookmarks.map((bookmark) {
          if (bookmark.label != 'deleted') return bookmark;
          return bookmark.copyWith(
            deletedAt: DateTime.utc(2026, 9, 14),
            revision: revision,
            tombstoneAckedByDeviceIds: <String>[manifest.deviceId],
          );
        }).toList();
        final remoteOnly = BookRecord(
          id: 'remote-sha',
          title: 'Remote only',
          fileName: 'remote.epub',
          format: 'epub',
          sizeBytes: 100,
          contentSha256: 'remote-sha',
          availableOnDeviceIds: const <String>['device-peer'],
          metadataRevision: revision,
          updatedByDeviceId: manifest.deviceId,
        );
        final deletedBook = BookRecord(
          id: 'deleted-sha',
          title: 'Deleted',
          fileName: 'deleted.fb2',
          format: 'fb2',
          sizeBytes: 1,
          contentSha256: 'deleted-sha',
          deletedAt: DateTime.utc(2026, 9, 14),
          metadataRevision: revision,
          tombstoneAckedByDeviceIds: <String>[manifest.deviceId],
          updatedByDeviceId: manifest.deviceId,
        );
        return manifest.copyWith(
          books: <BookRecord>[
            book.copyWith(bookmarks: bookmarks),
            remoteOnly,
            deletedBook,
          ],
          trustedDevices: <TrustedDeviceRecord>[
            ...manifest.trustedDevices,
            TrustedDeviceRecord(deviceId: 'device-peer', name: 'Peer', publicKey: 'PEER-PUBLIC'),
          ],
          logicalClock: revision.counter,
          appliedOperationIds: const <String>['operation-before-reinstall'],
        );
      });
      await storageA.flushPortableState();
      final recovery = await storageA.createRecoveryKey();
      await storageA.confirmRecoveryKey(recovery.displayKey);
      old = await storageA.loadManifest();
      final oldAccountId = old.accountId;
      final oldAccountKey = old.accountEncryptionKey;
      final oldDeviceId = old.deviceId;
      final oldPrivateKey = old.deviceSigningPrivateKey;

      final archive = Directory('${root.path}/Archive');
      await archive.create();
      await source.rename('${archive.path}/book.txt');
      await storageA.dispose();
      await sandboxA.delete(recursive: true);

      final storageB = StorageService(
        appDirectory: () async => sandboxB,
        secretStore: _MemorySecretStore(),
        libraryStorageProvider: provider,
      );
      await storageB.configureLibraryRoot(rootHandle, bootstrapPortableState: false);
      final before = await storageB.loadManifest();
      expect(before.deviceId, isNot(oldDeviceId));
      expect(before.deviceSigningPrivateKey, isNot(oldPrivateKey));

      final recovered = await storageB.recoverWithRecoveryKey(recovery.displayKey);
      expect(recovered.accountId, oldAccountId);
      expect(recovered.accountEncryptionKey, oldAccountKey);
      expect(recovered.deviceId, isNot(oldDeviceId));
      expect(recovered.deviceSigningPrivateKey, isNot(oldPrivateKey));
      final recoveredBook = recovered.books.singleWhere((book) => book.id == bookId);
      expect(recoveredBook.relativeLocation, 'Archive/book.txt');
      expect(recoveredBook.progressPercent, 63);
      expect(recoveredBook.currentLocator, 'paragraph:42');
      expect(recoveredBook.visibleBookmarks.map((bookmark) => bookmark.label), contains('keep'));
      expect(recoveredBook.bookmarks.singleWhere((bookmark) => bookmark.label == 'deleted').isDeleted, isTrue);
      expect(recovered.books.singleWhere((book) => book.id == 'remote-sha').relativeLocation, isNull);
      expect(recovered.books.singleWhere((book) => book.id == 'deleted-sha').isDeleted, isTrue);
      expect(recovered.appliedOperationIds, contains('operation-before-reinstall'));
      await storageB.dispose();
    } finally {
      if (await temp.exists()) await temp.delete(recursive: true);
    }
  });
}

LibraryManifest _manifest({
  required String deviceId,
  String privateKey = 'PRIVATE',
  double progress = 20,
  List<BookRecord>? books,
}) {
  final accountKey = base64UrlEncode(List<int>.generate(32, (index) => index + 1)).replaceAll('=', '');
  final revision = SyncRevision(counter: 5, deviceId: deviceId);
  final book = BookRecord(
    id: 'book-sha',
    title: 'Book',
    fileName: 'book.epub',
    format: 'epub',
    sizeBytes: 123,
    contentSha256: 'book-sha',
    progressPercent: progress,
    currentLocator: 'epub:c1',
    progressVersion: 5,
    updatedByDeviceId: deviceId,
    metadataRevision: revision,
    progressRevision: revision,
    availableOnDeviceIds: <String>[deviceId],
    bookmarks: <BookmarkRecord>[
      BookmarkRecord(id: 'bookmark-live', bookId: 'book-sha', label: 'Live', locator: 'epub:c1', revision: revision),
      BookmarkRecord(
        id: 'bookmark-deleted',
        bookId: 'book-sha',
        label: 'Deleted',
        locator: 'epub:c0',
        deletedAt: DateTime.utc(2026),
        revision: revision,
        tombstoneAckedByDeviceIds: <String>[deviceId],
      ),
    ],
  );
  return LibraryManifest(
    accountId: 'account-q',
    accountEncryptionKey: accountKey,
    deviceId: deviceId,
    deviceName: deviceId,
    deviceSigningPublicKey: 'PUBLIC-$deviceId',
    deviceSigningPrivateKey: privateKey,
    books: books ?? <BookRecord>[book],
    trustedDevices: <TrustedDeviceRecord>[
      TrustedDeviceRecord(deviceId: deviceId, name: deviceId, role: 'owner', publicKey: 'PUBLIC-$deviceId'),
    ],
    logicalClock: 5,
    appliedOperationIds: const <String>['operation-1'],
  );
}

Future<String> _readReadArc(Directory root) async {
  final buffer = StringBuffer();
  final directory = Directory('${root.path}/.readarc');
  if (!await directory.exists()) return '';
  await for (final entity in directory.list(recursive: true)) {
    if (entity is File) {
      buffer.writeln(await entity.readAsString());
    }
  }
  return buffer.toString();
}

class _MemorySecretStore implements LibrarySecretStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}
