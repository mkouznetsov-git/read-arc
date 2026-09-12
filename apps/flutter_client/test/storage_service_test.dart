import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
    expect((await restarted.refreshLibrary())?.books.single.id, imported.id);
  });
}

class _MemorySecretStore implements LibrarySecretStore {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;
}
