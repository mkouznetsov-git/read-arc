import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:readarc/models/book.dart';
import 'package:readarc/services/library_repository.dart';
import 'package:readarc/services/library_storage.dart';
import 'package:readarc/services/book_import_service.dart';
import 'package:readarc/services/storage_service.dart';

void main() {
  test('default repository resolves its application directory without recursion', () async {
    final directory = await Directory.systemTemp.createTemp('readarc-storage-service-');
    addTearDown(() async => directory.delete(recursive: true));
    final storage = StorageService(appDirectory: () async => directory, secretStore: _MemorySecretStore());

    final first = await storage.loadManifest().timeout(const Duration(seconds: 3));
    final second = await storage.loadManifest().timeout(const Duration(seconds: 3));

    expect(first.accountId, isNotEmpty);
    expect(second.accountId, first.accountId);
    expect(await File('${directory.path}/manifest.json').exists(), isTrue);
  });

  test('cold-start application directory resolution is single-flight', () async {
    final directory = await Directory.systemTemp.createTemp('readarc-storage-single-flight-');
    addTearDown(() async => directory.delete(recursive: true));
    var resolutions = 0;
    final gate = Completer<void>();
    final storage = StorageService(
      appDirectory: () async {
        resolutions += 1;
        await gate.future;
        return directory;
      },
      secretStore: _MemorySecretStore(),
    );

    final first = storage.appDir();
    final second = storage.appDir();
    final third = storage.appDir();
    await Future<void>.delayed(Duration.zero);

    expect(resolutions, 1, reason: 'parallel cold-start consumers must share one directory/migration lookup');
    gate.complete();
    final resolved = await Future.wait([first, second, third]);
    expect(resolved.map((item) => item.path).toSet(), {directory.path});
    expect(resolutions, 1);

    expect((await storage.appDir()).path, directory.path);
    expect(resolutions, 1, reason: 'resolved app directory must be reused for the lifetime of StorageService');
  });

  test('selected user-owned root persists and import writes no private books copy', () async {
    final application = await Directory.systemTemp.createTemp('readarc-storage-app-');
    final library = await Directory.systemTemp.createTemp('readarc-storage-root-');
    final sourceDirectory = await Directory.systemTemp.createTemp('readarc-import-source-');
    addTearDown(() async {
      for (final directory in [application, library, sourceDirectory]) {
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    });
    final secrets = _MemorySecretStore();
    final provider = LocalDirectoryLibraryStorageProvider();
    final root = LibraryRoot(kind: LibraryRootKind.desktopPath, locator: library.path, displayName: 'Library');
    final storage = StorageService(
      appDirectory: () async => application,
      secretStore: secrets,
      libraryStorageProvider: provider,
    );
    await storage.configureLibraryRoot(root);
    final source = File('${sourceDirectory.path}/manual.epub');
    await source.writeAsString('user owned bytes', flush: true);

    final imported = await BookImportService(storage).importFile(source);

    expect(imported.relativeLocation, 'manual.epub');
    expect(await File('${library.path}/manual.epub').readAsString(), 'user owned bytes');
    expect(await Directory('${application.path}/books').exists(), isFalse);
    final restarted = StorageService(
      appDirectory: () async => application,
      secretStore: secrets,
      libraryStorageProvider: provider,
    );
    expect((await restarted.configuredLibraryRoot())?.locator, library.path);
    await File('${application.path}/library_index.json').delete();
    expect(await (await restarted.materializeBook(imported)).readAsString(), 'user owned bytes');
    expect((await restarted.refreshLibrary())?.books.single.id, imported.id);
  });

  test('same SHA import reuses the existing root file while filename collisions stay distinct', () async {
    final application = await Directory.systemTemp.createTemp('readarc-dedupe-app-');
    final library = await Directory.systemTemp.createTemp('readarc-dedupe-root-');
    final sources = await Directory.systemTemp.createTemp('readarc-dedupe-source-');
    addTearDown(() async {
      for (final directory in [application, library, sources]) {
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    });
    final storage = StorageService(
      appDirectory: () async => application,
      secretStore: _MemorySecretStore(),
      libraryStorageProvider: LocalDirectoryLibraryStorageProvider(),
    );
    final root = LibraryRoot(kind: LibraryRootKind.desktopPath, locator: library.path, displayName: 'Library');
    await storage.configureLibraryRoot(root);
    await File(p.join(library.path, 'existing.epub')).writeAsString('same bytes', flush: true);
    final duplicate = File(p.join(sources.path, 'duplicate.epub'))..writeAsStringSync('same bytes', flush: true);

    final reused = await BookImportService(storage).importFile(duplicate);
    expect(reused.relativeLocation, 'existing.epub');
    expect(await library.list().where((entity) => entity is File).length, 1);

    final collision = File(p.join(sources.path, 'existing.epub'))..writeAsStringSync('different bytes', flush: true);
    final second = await BookImportService(storage).importFile(collision);
    expect(second.relativeLocation, 'existing (2).epub');
    expect(await library.list().where((entity) => entity is File).length, 2);
  });

  test('unavailable or interrupted full scan never reconciles as mass deletion', () async {
    final application = await Directory.systemTemp.createTemp('readarc-unavailable-app-');
    final library = await Directory.systemTemp.createTemp('readarc-unavailable-root-');
    final sourceDirectory = await Directory.systemTemp.createTemp('readarc-unavailable-source-');
    addTearDown(() async {
      for (final directory in [application, library, sourceDirectory]) {
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    });
    final provider = _ToggleProvider(LocalDirectoryLibraryStorageProvider());
    final storage = StorageService(
      appDirectory: () async => application,
      secretStore: _MemorySecretStore(),
      libraryStorageProvider: provider,
    );
    final root = LibraryRoot(kind: LibraryRootKind.desktopPath, locator: library.path, displayName: 'Library');
    await storage.configureLibraryRoot(root);
    final source = File(p.join(sourceDirectory.path, 'book.epub'))..writeAsStringSync('book', flush: true);
    final imported = await BookImportService(storage).importFile(source);
    final before = await storage.loadManifest();

    provider.rootStatus = LibraryRootStatus.temporarilyUnavailable;
    await expectLater(
      storage.refreshLibrary(),
      throwsA(
        isA<LibraryRootAccessException>().having(
          (error) => error.status,
          'status',
          LibraryRootStatus.temporarilyUnavailable,
        ),
      ),
    );

    provider
      ..rootStatus = LibraryRootStatus.available
      ..failListing = true;
    await expectLater(storage.refreshLibrary(), throwsA(isA<FileSystemException>()));

    final after = await storage.loadManifest();
    final retained = after.books.singleWhere((book) => book.id == imported.id);
    expect(retained.relativeLocation, imported.relativeLocation);
    expect(retained.availableOnDeviceIds, before.books.single.availableOnDeviceIds);
    expect(retained.deletedAt, isNull);
    expect(after.logicalClock, before.logicalClock);
  });

  test('delete while root is unavailable neither removes metadata nor emits a tombstone', () async {
    final application = await Directory.systemTemp.createTemp('readarc-delete-unavailable-app-');
    final library = await Directory.systemTemp.createTemp('readarc-delete-unavailable-root-');
    final sources = await Directory.systemTemp.createTemp('readarc-delete-unavailable-source-');
    addTearDown(() async {
      for (final directory in [application, library, sources]) {
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    });
    final provider = _ToggleProvider(LocalDirectoryLibraryStorageProvider());
    final storage = StorageService(
      appDirectory: () async => application,
      secretStore: _MemorySecretStore(),
      libraryStorageProvider: provider,
    );
    await storage.configureLibraryRoot(
      LibraryRoot(kind: LibraryRootKind.desktopPath, locator: library.path, displayName: 'Library'),
    );
    final source = File(p.join(sources.path, 'book.epub'))..writeAsStringSync('book', flush: true);
    final imported = await BookImportService(storage).importFile(source);
    final before = await storage.loadManifest();

    provider.rootStatus = LibraryRootStatus.temporarilyUnavailable;
    await expectLater(
      storage.deleteBookFromLibrary(imported.id),
      throwsA(
        isA<LibraryRootAccessException>().having(
          (error) => error.status,
          'status',
          LibraryRootStatus.temporarilyUnavailable,
        ),
      ),
    );

    final retained = (await storage.loadManifest()).books.singleWhere((book) => book.id == imported.id);
    expect(retained.isDeleted, isFalse);
    expect(retained.relativeLocation, imported.relativeLocation);
    expect((await storage.loadManifest()).logicalClock, before.logicalClock);
    expect(await File(p.join(library.path, 'book.epub')).exists(), isTrue);
  });

  test('removing a logical local copy deletes every duplicate SHA location', () async {
    final application = await Directory.systemTemp.createTemp('readarc-delete-duplicates-app-');
    final library = await Directory.systemTemp.createTemp('readarc-delete-duplicates-root-');
    addTearDown(() async {
      for (final directory in [application, library]) {
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    });
    await File(p.join(library.path, 'A', 'book.epub')).create(recursive: true);
    await File(p.join(library.path, 'A', 'book.epub')).writeAsString('same', flush: true);
    await File(p.join(library.path, 'B', 'copy.epub')).create(recursive: true);
    await File(p.join(library.path, 'B', 'copy.epub')).writeAsString('same', flush: true);
    final storage = StorageService(
      appDirectory: () async => application,
      secretStore: _MemorySecretStore(),
      libraryStorageProvider: LocalDirectoryLibraryStorageProvider(),
    );
    await storage.configureLibraryRoot(
      LibraryRoot(kind: LibraryRootKind.desktopPath, locator: library.path, displayName: 'Library'),
    );
    final book = (await storage.loadManifest()).books.single;

    final manifest = await storage.removeLocalBookCopy(book.id);

    expect(await File(p.join(library.path, 'A', 'book.epub')).exists(), isFalse);
    expect(await File(p.join(library.path, 'B', 'copy.epub')).exists(), isFalse);
    final removed = manifest.books.singleWhere((candidate) => candidate.id == book.id);
    expect(removed.isDeleted, isFalse);
    expect(removed.hasLocalSource, isFalse);
  });

  test('failed migration resume does not cache a pending target as canonical root', () async {
    final application = await Directory.systemTemp.createTemp('readarc-pending-app-');
    final library = await Directory.systemTemp.createTemp('readarc-pending-root-');
    addTearDown(() async {
      for (final directory in [application, library]) {
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    });
    final target = LibraryRoot(kind: LibraryRootKind.desktopPath, locator: library.path, displayName: 'Library');
    await File(p.join(application.path, 'library_migration.json')).writeAsString(
      jsonEncode({'schemaVersion': 1, 'target': target.toJson(), 'completed': false, 'items': {}}),
      flush: true,
    );
    final provider = _ToggleProvider(LocalDirectoryLibraryStorageProvider())
      ..rootStatus = LibraryRootStatus.temporarilyUnavailable;
    final storage = StorageService(
      appDirectory: () async => application,
      secretStore: _MemorySecretStore(),
      libraryStorageProvider: provider,
    );

    expect(await storage.resumePendingLibraryMigration(), isFalse);
    expect(await storage.configuredLibraryRoot(), isNull);
    expect(await File(p.join(application.path, 'library_root.json')).exists(), isFalse);
  });

  test('corrupt persisted root consistently requires re-selection on every access', () async {
    final application = await Directory.systemTemp.createTemp('readarc-corrupt-root-app-');
    addTearDown(() async {
      if (await application.exists()) await application.delete(recursive: true);
    });
    await File(p.join(application.path, 'library_root.json')).writeAsString('{broken', flush: true);
    final storage = StorageService(
      appDirectory: () async => application,
      secretStore: _MemorySecretStore(),
      libraryStorageProvider: LocalDirectoryLibraryStorageProvider(),
    );

    for (var attempt = 0; attempt < 2; attempt++) {
      await expectLater(
        storage.configuredLibraryRoot(),
        throwsA(
          isA<LibraryRootAccessException>().having((error) => error.status, 'status', LibraryRootStatus.permissionLost),
        ),
      );
    }
  });

  test('recovery-required root stays portable-write-suppressed until an account choice succeeds', () async {
    final application = await Directory.systemTemp.createTemp('readarc-recovery-pending-app-');
    final library = await Directory.systemTemp.createTemp('readarc-recovery-pending-root-');
    addTearDown(() async {
      for (final directory in [application, library]) {
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    });
    final storage = StorageService(
      appDirectory: () async => application,
      secretStore: _MemorySecretStore(),
      libraryStorageProvider: LocalDirectoryLibraryStorageProvider(),
    );
    final manifest = await storage.loadManifest();
    final root = LibraryRoot(kind: LibraryRootKind.desktopPath, locator: library.path, displayName: 'Library');

    await storage.configureLibraryRoot(root, bootstrapPortableState: false);
    await storage.mutateManifest((current) => current.copyWith(logicalClock: current.logicalClock + 1));
    await storage.flushPortableState();
    await storage.dispose();

    final current = File(p.join(library.path, '.readarc', 'state', manifest.deviceId, 'current'));
    expect(await current.exists(), isFalse, reason: 'pairing cancellation/background must not publish a fresh account');

    await storage.startNewAccountForPortableLibrary();
    expect(await current.exists(), isTrue, reason: 'an explicit new-account choice enables portable writes');
  });

  test('verified transfer destination is committed to user root and incoming cache is removed', () async {
    final application = await Directory.systemTemp.createTemp('readarc-transfer-app-');
    final library = await Directory.systemTemp.createTemp('readarc-transfer-root-');
    addTearDown(() async {
      for (final directory in [application, library]) {
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    });
    final storage = StorageService(
      appDirectory: () async => application,
      secretStore: _MemorySecretStore(),
      libraryStorageProvider: LocalDirectoryLibraryStorageProvider(),
    );
    final root = LibraryRoot(kind: LibraryRootKind.desktopPath, locator: library.path, displayName: 'Library');
    await storage.configureLibraryRoot(root);
    final incoming = File(p.join(application.path, 'incoming', 'book.part'));
    await incoming.parent.create(recursive: true);
    await incoming.writeAsString('transferred bytes', flush: true);
    final hash = (await sha256.bind(incoming.openRead()).first).toString();
    final remote = BookRecord(
      id: hash,
      title: 'Transferred',
      fileName: 'transferred.epub',
      format: 'epub',
      sizeBytes: await incoming.length(),
      contentSha256: hash,
      availableOnDeviceIds: const ['remote-device'],
    );
    await storage.upsertBook(remote);

    final manifest = await storage.commitReceivedBook(book: remote, verifiedFile: incoming);

    expect(await incoming.exists(), isFalse);
    expect(await File(p.join(library.path, 'transferred.epub')).readAsString(), 'transferred bytes');
    expect(manifest.books.singleWhere((book) => book.id == hash).relativeLocation, 'transferred.epub');
    expect(await Directory(p.join(application.path, 'books')).exists(), isFalse);
  });
}

class _MemorySecretStore implements LibrarySecretStore {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;
}

class _ToggleProvider implements LibraryStorageProvider {
  _ToggleProvider(this.delegate);

  final LibraryStorageProvider delegate;
  LibraryRootStatus rootStatus = LibraryRootStatus.available;
  bool failListing = false;

  @override
  Future<LibraryRoot?> chooseRoot() => delegate.chooseRoot();
  @override
  Future<LibraryRoot> refreshRoot(LibraryRoot root) => delegate.refreshRoot(root);
  @override
  Future<LibraryRootStatus> status(LibraryRoot root) async => rootStatus;
  @override
  Future<List<LibraryEntry>> listEntries(LibraryRoot root) {
    if (rootStatus != LibraryRootStatus.available) {
      throw LibraryRootAccessException(rootStatus, 'unavailable');
    }
    if (failListing) throw const FileSystemException('interrupted full traversal');
    return delegate.listEntries(root);
  }

  @override
  Future<String> contentSha256(LibraryRoot root, LibraryEntry entry) => delegate.contentSha256(root, entry);
  @override
  Future<File> materialize(LibraryRoot root, LibraryEntry entry, Directory cacheDirectory) =>
      delegate.materialize(root, entry, cacheDirectory);
  @override
  Future<String> importFile(LibraryRoot root, File source, {required String preferredName}) =>
      delegate.importFile(root, source, preferredName: preferredName);
  @override
  Future<void> deleteEntry(LibraryRoot root, String relativeLocation) => delegate.deleteEntry(root, relativeLocation);
  @override
  Future<bool> containsFile(LibraryRoot root, File source) => delegate.containsFile(root, source);
  @override
  Future<Uint8List?> readServiceFile(LibraryRoot root, String relativeLocation) =>
      delegate.readServiceFile(root, relativeLocation);
  @override
  Future<List<String>> listServiceFiles(LibraryRoot root, String relativeDirectory) =>
      delegate.listServiceFiles(root, relativeDirectory);
  @override
  Future<void> publishServiceFile(
    LibraryRoot root,
    String relativeLocation,
    Uint8List bytes, {
    bool preservePrevious = true,
  }) => delegate.publishServiceFile(root, relativeLocation, bytes, preservePrevious: preservePrevious);
}
