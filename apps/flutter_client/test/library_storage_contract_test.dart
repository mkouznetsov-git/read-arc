import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readarc/models/book.dart';
import 'package:readarc/services/book_import_service.dart';
import 'package:readarc/services/library_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('readarc/library_storage.test');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('platform abstraction carries an opaque root and relative locations only', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'chooseRoot') {
        return {'kind': 'androidTreeUri', 'locator': 'content://opaque/tree', 'displayName': 'Books'};
      }
      if (call.method == 'status') return 'available';
      if (call.method == 'listEntries') {
        return [
          {
            'relativeLocation': 'Work/Patton.epub',
            'sizeBytes': 42,
            'modifiedAt': '2026-09-12T00:00:00Z',
            'availability': 'available',
          },
        ];
      }
      return null;
    });
    final provider = PlatformLibraryStorageProvider(channel: channel);

    final root = await provider.chooseRoot();
    final entries = await provider.listEntries(root!);

    expect(root.kind, LibraryRootKind.androidTreeUri);
    expect(root.locator, 'content://opaque/tree');
    expect(entries.single.relativeLocation, 'Work/Patton.epub');
    expect(entries.single.relativeLocation, isNot(contains('content://')));
  });

  test('platform permission loss has a typed application-level state', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'permissionLost'),
    );
    final provider = PlatformLibraryStorageProvider(channel: channel);
    const root = LibraryRoot(
      kind: LibraryRootKind.appleSecurityScopedBookmark,
      locator: 'opaque-bookmark',
      displayName: 'Books',
    );

    expect(await provider.status(root), LibraryRootStatus.permissionLost);
  });

  test('platform can refresh an opaque stale root without exposing its locator to domain data', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'refreshRoot') {
        return {'kind': 'appleSecurityScopedBookmark', 'locator': 'refreshed-bookmark-bytes', 'displayName': 'Books'};
      }
      return null;
    });
    final provider = PlatformLibraryStorageProvider(channel: channel);
    const root = LibraryRoot(
      kind: LibraryRootKind.appleSecurityScopedBookmark,
      locator: 'stale-bookmark-bytes',
      displayName: 'Books',
    );

    final refreshed = await provider.refreshRoot(root);

    expect(refreshed.locator, 'refreshed-bookmark-bytes');
    expect(refreshed.kind, LibraryRootKind.appleSecurityScopedBookmark);
  });

  test('sync JSON strips all device-local source locators', () {
    final book = BookRecord(
      id: 'sha',
      title: 'Book',
      fileName: 'Book.epub',
      format: 'epub',
      sizeBytes: 1,
      contentSha256: 'sha',
      localPath: '/private/cache/book.epub',
      relativeLocation: 'Fiction/Book.epub',
      sourceAvailability: 'available',
    );

    final synced = book.toJson(includeLocalPath: false);

    expect(synced, isNot(contains('localPath')));
    expect(synced, isNot(contains('relativeLocation')));
    expect(synced, isNot(contains('sourceAvailability')));
  });

  test('local provider does not copy a source already inside the root', () async {
    final directory = await Directory.systemTemp.createTemp('readarc-contained-');
    addTearDown(() async => directory.delete(recursive: true));
    final source = File('${directory.path}/Nested/book.txt');
    await source.parent.create(recursive: true);
    await source.writeAsString('book');
    final provider = LocalDirectoryLibraryStorageProvider();
    final root = LibraryRoot(kind: LibraryRootKind.desktopPath, locator: directory.path, displayName: 'Library');

    final relative = await provider.importFile(root, source, preferredName: 'book.txt');

    expect(relative, 'Nested/book.txt');
    expect(
      await directory.list(recursive: true).where((entity) => entity is File).map((entity) => entity as File).toList(),
      hasLength(1),
    );
  });

  test('discoverable formats are either readable or explicitly store-only', () {
    expect(readableBookExtensions, ['pdf', 'doc', 'docx', 'txt', 'fb2', 'djvu', 'djv', 'epub']);
    expect(storeOnlyBookExtensions, ['chm', 'mobi', 'azw3', 'cbz', 'xps']);
    expect(supportedBookExtensions, [...readableBookExtensions, ...storeOnlyBookExtensions]);
    expect(BookImportService.supportedExtensions, readableBookExtensions);
  });

  test('relative locations reject traversal, absolute and ambiguous segments', () {
    for (final invalid in ['../book.epub', 'A/../book.epub', '/book.epub', 'A//book.epub', './book.epub']) {
      expect(
        () => LibraryEntry.fromJson({'relativeLocation': invalid, 'sizeBytes': 1, 'availability': 'available'}),
        throwsFormatException,
        reason: invalid,
      );
    }
  });

  test('interrupted desktop import exposes neither final book nor supported partial file', () async {
    final rootDirectory = await Directory.systemTemp.createTemp('readarc-atomic-root-');
    final sourceDirectory = await Directory.systemTemp.createTemp('readarc-atomic-source-');
    addTearDown(() async {
      if (await rootDirectory.exists()) await rootDirectory.delete(recursive: true);
      if (await sourceDirectory.exists()) await sourceDirectory.delete(recursive: true);
    });
    final source = File('${sourceDirectory.path}/book.epub');
    await source.writeAsString('complete bytes', flush: true);
    final provider = LocalDirectoryLibraryStorageProvider(
      afterStagedCopy: (_) async => throw StateError('simulated process interruption'),
    );
    final root = LibraryRoot(kind: LibraryRootKind.desktopPath, locator: rootDirectory.path, displayName: 'Library');

    await expectLater(provider.importFile(root, source, preferredName: 'book.epub'), throwsStateError);

    final entries = await rootDirectory.list(recursive: true).where((entity) => entity is File).toList();
    expect(entries, isEmpty);
  });
}
