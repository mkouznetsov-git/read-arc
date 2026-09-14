import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:readarc/models/book.dart';
import 'package:readarc/services/library_scanner.dart';
import 'package:readarc/services/library_storage.dart';

void main() {
  late Directory rootDirectory;
  late Directory cacheDirectory;
  late LibraryRoot root;
  late _CountingProvider provider;

  setUp(() async {
    rootDirectory = await Directory.systemTemp.createTemp('readarc-user-library-');
    cacheDirectory = await Directory.systemTemp.createTemp('readarc-cache-');
    root = LibraryRoot(kind: LibraryRootKind.desktopPath, locator: rootDirectory.path, displayName: 'Library');
    provider = _CountingProvider(LocalDirectoryLibraryStorageProvider());
  });

  tearDown(() async {
    if (await rootDirectory.exists()) await rootDirectory.delete(recursive: true);
    if (await cacheDirectory.exists()) await cacheDirectory.delete(recursive: true);
  });

  Future<void> writeBook(String relative, String contents) async {
    final file = File(p.joinAll(<String>[rootDirectory.path, ...p.posix.split(relative)]));
    await file.parent.create(recursive: true);
    await file.writeAsString(contents, flush: true);
  }

  test('empty root produces an empty index without inventing a library', () async {
    final result = await _scan(provider, root);
    expect(result.books, isEmpty);
    expect(result.index.entries, isEmpty);
  });

  test('recursive discovery keeps relative folders and filters unsupported extensions', () async {
    await writeBook('Fiction/SciFi/book.epub', 'epub');
    await writeBook('Work/manual.PDF', 'pdf');
    await writeBook('notes.md', 'ignored');

    final result = await _scan(provider, root);

    expect(result.index.entries.map((item) => item.relativeLocation), ['Fiction/SciFi/book.epub', 'Work/manual.PDF']);
    expect(result.books.map((item) => item.format).toSet(), {'epub', 'pdf'});
  });

  test('reserved .readarc namespace is never indexed as user book content', () async {
    await writeBook('.readarc/portable-metadata.epub', 'not a book');
    await writeBook('.READARC/cache/book.pdf', 'also reserved on case-insensitive roots');
    await writeBook('Fiction/book.epub', 'book');

    final result = await _scan(provider, root);

    expect(result.books.single.relativeLocation, 'Fiction/book.epub');
    expect(result.index.entries.single.relativeLocation, 'Fiction/book.epub');
    expect(await File(p.join(rootDirectory.path, '.readarc/portable-metadata.epub')).exists(), isTrue);
  });

  test('desktop scanner never follows file or directory symlinks outside root', () async {
    final outside = await Directory.systemTemp.createTemp('readarc-outside-root-');
    addTearDown(() async {
      if (await outside.exists()) await outside.delete(recursive: true);
    });
    await File(p.join(outside.path, 'outside.epub')).writeAsString('outside');
    await Link(p.join(rootDirectory.path, 'linked-directory')).create(outside.path);
    await Link(p.join(rootDirectory.path, 'linked-book.epub')).create(p.join(outside.path, 'outside.epub'));
    await writeBook('inside.epub', 'inside');

    final result = await _scan(provider, root);

    expect(result.books.single.relativeLocation, 'inside.epub');
    expect(result.index.entries.single.relativeLocation, 'inside.epub');
  });

  test('unchanged fingerprint reuses SHA and does not hash file again', () async {
    await writeBook('book.fb2', 'same');
    final first = await _scan(provider, root);
    expect(provider.hashCalls, 1);

    final second = await _scan(provider, root, index: first.index, books: first.books);

    expect(second.hashedFiles, 0);
    expect(provider.hashCalls, 1);
    expect(second.books.single.id, first.books.single.id);
  });

  test('new, removed and content-changed books are reconciled', () async {
    await writeBook('old.txt', 'old');
    final first = await _scan(provider, root);
    await File(p.join(rootDirectory.path, 'old.txt')).delete();
    await writeBook('new.txt', 'new');

    final second = await _scan(provider, root, index: first.index, books: first.books);
    expect(second.books.where((book) => book.hasLocalSource).map((book) => book.fileName), ['new.txt']);
    expect(second.books.singleWhere((book) => book.id == first.books.single.id).hasLocalSource, isFalse);

    final current = second.books.firstWhere((book) => book.hasLocalSource);
    final progressedBooks = second.books
        .map((book) => book.id == current.id ? book.copyWith(progressPercent: 88, currentLocator: 'old-content') : book)
        .toList();
    await writeBook('new.txt', 'changed and longer');
    final third = await _scan(provider, root, index: second.index, books: progressedBooks);
    expect(
      third.books.where((book) => book.hasLocalSource).single.id,
      isNot(second.books.firstWhere((b) => b.hasLocalSource).id),
    );
    final replacement = third.books.where((book) => book.hasLocalSource).single;
    expect(replacement.progressPercent, 0, reason: 'replacement content must not inherit old progress');
    expect(third.books.singleWhere((book) => book.id == current.id).progressPercent, 88);
  });

  test('rename and move retain content identity, progress, locator and bookmarks', () async {
    await writeBook('Work/book.epub', 'identity');
    final first = await _scan(provider, root);
    final bookmark = BookmarkRecord(id: 'mark', bookId: first.books.single.id, label: 'Saved', locator: 'anchor');
    final progressed = first.books.single.copyWith(
      progressPercent: 61,
      currentLocator: 'locator-61',
      bookmarks: [bookmark],
    );
    await Directory(p.join(rootDirectory.path, 'Archive')).create();
    await File(p.join(rootDirectory.path, 'Work/book.epub')).rename(p.join(rootDirectory.path, 'Archive/renamed.epub'));

    final moved = await _scan(provider, root, index: first.index, books: [progressed]);
    final book = moved.books.single;

    expect(book.id, progressed.id);
    expect(book.relativeLocation, 'Archive/renamed.epub');
    expect(book.progressPercent, 61);
    expect(book.currentLocator, 'locator-61');
    expect(book.bookmarks.single.id, 'mark');
  });

  test('duplicate content in two paths remains one logical book while index retains both locations', () async {
    await writeBook('A/book.pdf', 'duplicate');
    await writeBook('B/copy.pdf', 'duplicate');

    final result = await _scan(provider, root);

    expect(result.books, hasLength(1));
    expect(result.index.entries, hasLength(2));
    expect(result.index.entries.map((entry) => entry.contentSha256).toSet(), hasLength(1));

    final progressed = result.books.single.copyWith(progressPercent: 73, currentLocator: 'duplicate-locator');
    await File(p.join(rootDirectory.path, 'A/book.pdf')).delete();
    final afterOneRemoval = await _scan(provider, root, index: result.index, books: [progressed]);
    expect(afterOneRemoval.books.single.id, progressed.id);
    expect(afterOneRemoval.books.single.relativeLocation, 'B/copy.pdf');
    expect(afterOneRemoval.books.single.progressPercent, 73);
    expect(afterOneRemoval.books.single.currentLocator, 'duplicate-locator');
  });

  test('root unavailable and permission lost fail without returning an empty scan', () async {
    for (final status in [LibraryRootStatus.temporarilyUnavailable, LibraryRootStatus.permissionLost]) {
      final unavailable = _UnavailableProvider(status);
      await expectLater(
        _scan(unavailable, root),
        throwsA(isA<LibraryRootAccessException>().having((error) => error.status, 'status', status)),
      );
    }
  });

  test('provider can report existence separately from offline byte availability', () async {
    final cloud = _CloudPlaceholderProvider();
    final old = LibraryIndex(
      entries: [
        LibraryIndexEntry(
          relativeLocation: 'Cloud/book.epub',
          sizeBytes: 10,
          contentSha256: 'known-sha',
          availability: LibraryEntryAvailability.available,
          modifiedAt: DateTime.utc(2026),
        ),
      ],
    );
    final result = await _scan(cloud, root, index: old);
    expect(result.index.entries.single.availability, LibraryEntryAvailability.requiresMaterialization);
    expect(result.index.entries.single.contentSha256, 'known-sha');
    expect(cloud.hashCalls, 0);
  });

  test('new cloud placeholder remains indexed without inventing a book identity', () async {
    final cloud = _CloudPlaceholderProvider();

    final result = await _scan(cloud, root);

    expect(result.books, isEmpty, reason: 'SHA identity cannot be invented before bytes are readable');
    expect(result.index.entries.single.relativeLocation, 'Cloud/book.epub');
    expect(result.index.entries.single.availability, LibraryEntryAvailability.requiresMaterialization);
    expect(result.index.entries.single.contentSha256, isEmpty);
    expect(result.index.entries.single.fingerprintVerified, isFalse);
    expect(cloud.hashCalls, 0);
  });

  test('changed cloud fingerprint is not trusted until bytes are materialized and hashed', () async {
    final changedAt = DateTime.utc(2026, 2);
    final cloud = _ChangingCloudProvider(changedAt);
    final old = LibraryIndex(
      entries: [
        LibraryIndexEntry(
          relativeLocation: 'Cloud/book.epub',
          sizeBytes: 10,
          contentSha256: 'old-sha',
          availability: LibraryEntryAvailability.available,
          modifiedAt: DateTime.utc(2026),
        ),
      ],
    );
    final placeholder = await _scan(cloud, root, index: old);
    expect(placeholder.index.entries.single.contentSha256, 'old-sha');
    expect(placeholder.index.entries.single.fingerprintVerified, isFalse);
    expect(cloud.hashCalls, 0);

    cloud.materialized = true;
    final materialized = await _scan(cloud, root, index: placeholder.index, books: placeholder.books);
    expect(cloud.hashCalls, 1);
    expect(materialized.index.entries.single.contentSha256, 'new-sha');
    expect(materialized.index.entries.single.fingerprintVerified, isTrue);
  });

  test('ambiguous duplicate relative locations abort the scan instead of partially reconciling', () async {
    final duplicate = _DuplicateLocationProvider();
    await expectLater(
      _scan(duplicate, root),
      throwsA(
        isA<LibraryRootAccessException>().having(
          (error) => error.status,
          'status',
          LibraryRootStatus.temporarilyUnavailable,
        ),
      ),
    );
    expect(duplicate.hashCalls, 0);
  });

  test('manual file addition is found and cache deletion cannot remove source book', () async {
    await writeBook('Manual/added.docx', 'manual');
    await File(p.join(cacheDirectory.path, 'throwaway')).writeAsString('cache');
    await cacheDirectory.delete(recursive: true);

    final result = await _scan(provider, root);

    expect(result.books.single.relativeLocation, 'Manual/added.docx');
    expect(await File(p.join(rootDirectory.path, 'Manual/added.docx')).readAsString(), 'manual');
  });
}

Future<LibraryScanResult> _scan(
  LibraryStorageProvider provider,
  LibraryRoot root, {
  LibraryIndex index = const LibraryIndex(),
  List<BookRecord> books = const [],
}) => LibraryScanner(provider).scan(root: root, previousIndex: index, previousBooks: books, deviceId: 'device');

class _CountingProvider implements LibraryStorageProvider {
  _CountingProvider(this.delegate);
  final LibraryStorageProvider delegate;
  int hashCalls = 0;

  @override
  Future<String> contentSha256(LibraryRoot root, LibraryEntry entry) {
    hashCalls += 1;
    return delegate.contentSha256(root, entry);
  }

  @override
  Future<LibraryRoot?> chooseRoot() => delegate.chooseRoot();
  @override
  Future<LibraryRoot> refreshRoot(LibraryRoot root) => delegate.refreshRoot(root);
  @override
  Future<bool> containsFile(LibraryRoot root, File source) => delegate.containsFile(root, source);
  @override
  Future<void> deleteEntry(LibraryRoot root, String relativeLocation) => delegate.deleteEntry(root, relativeLocation);
  @override
  Future<String> importFile(LibraryRoot root, File source, {required String preferredName}) =>
      delegate.importFile(root, source, preferredName: preferredName);
  @override
  Future<List<LibraryEntry>> listEntries(LibraryRoot root) => delegate.listEntries(root);
  @override
  Future<File> materialize(LibraryRoot root, LibraryEntry entry, Directory cacheDirectory) =>
      delegate.materialize(root, entry, cacheDirectory);
  @override
  Future<LibraryRootStatus> status(LibraryRoot root) =>
      delegate.status(root);
  @override
  Future<Uint8List?> readServiceFile(
    LibraryRoot root,
    String relativeLocation,
  ) => delegate.readServiceFile(root, relativeLocation);
  @override
  Future<List<String>> listServiceFiles(
    LibraryRoot root,
    String relativeDirectory,
  ) => delegate.listServiceFiles(root, relativeDirectory);
  @override
  Future<void> publishServiceFile(
    LibraryRoot root,
    String relativeLocation,
    Uint8List bytes, {
    bool preservePrevious = true,
  }) => delegate.publishServiceFile(
    root,
    relativeLocation,
    bytes,
    preservePrevious: preservePrevious,
  );
}

class _UnavailableProvider implements LibraryStorageProvider {
  _UnavailableProvider(this.rootStatus);
  final LibraryRootStatus rootStatus;
  @override
  Future<LibraryRootStatus> status(LibraryRoot root) async => rootStatus;
  @override
  Future<LibraryRoot> refreshRoot(LibraryRoot root) async => root;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CloudPlaceholderProvider extends _UnavailableProvider {
  _CloudPlaceholderProvider() : super(LibraryRootStatus.available);
  int hashCalls = 0;

  @override
  Future<List<LibraryEntry>> listEntries(LibraryRoot root) async => [
    LibraryEntry(
      relativeLocation: 'Cloud/book.epub',
      sizeBytes: 10,
      modifiedAt: DateTime.utc(2026),
      availability: LibraryEntryAvailability.requiresMaterialization,
    ),
  ];

  @override
  Future<String> contentSha256(LibraryRoot root, LibraryEntry entry) async {
    hashCalls += 1;
    return 'unexpected';
  }
}

class _ChangingCloudProvider extends _UnavailableProvider {
  _ChangingCloudProvider(this.modifiedAt) : super(LibraryRootStatus.available);

  final DateTime modifiedAt;
  bool materialized = false;
  int hashCalls = 0;

  @override
  Future<List<LibraryEntry>> listEntries(LibraryRoot root) async => [
    LibraryEntry(
      relativeLocation: 'Cloud/book.epub',
      sizeBytes: 20,
      modifiedAt: modifiedAt,
      availability: materialized
          ? LibraryEntryAvailability.available
          : LibraryEntryAvailability.requiresMaterialization,
    ),
  ];

  @override
  Future<String> contentSha256(LibraryRoot root, LibraryEntry entry) async {
    hashCalls += 1;
    return 'new-sha';
  }
}

class _DuplicateLocationProvider extends _UnavailableProvider {
  _DuplicateLocationProvider() : super(LibraryRootStatus.available);
  int hashCalls = 0;

  @override
  Future<List<LibraryEntry>> listEntries(LibraryRoot root) async => [
    const LibraryEntry(
      relativeLocation: 'duplicate.epub',
      sizeBytes: 1,
      availability: LibraryEntryAvailability.available,
    ),
    const LibraryEntry(
      relativeLocation: 'duplicate.epub',
      sizeBytes: 2,
      availability: LibraryEntryAvailability.available,
    ),
  ];

  @override
  Future<String> contentSha256(LibraryRoot root, LibraryEntry entry) async {
    hashCalls += 1;
    return 'unexpected';
  }
}
