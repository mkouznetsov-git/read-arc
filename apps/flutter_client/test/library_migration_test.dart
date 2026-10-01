import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:readarc/models/book.dart';
import 'package:readarc/services/library_migration.dart';
import 'package:readarc/services/library_storage.dart';

void main() {
  late Directory privateDirectory;
  late Directory rootDirectory;
  late File journalFile;
  late LibraryRoot root;
  late LocalDirectoryLibraryStorageProvider provider;

  setUp(() async {
    privateDirectory = await Directory.systemTemp.createTemp('readarc-private-');
    rootDirectory = await Directory.systemTemp.createTemp('readarc-owned-root-');
    journalFile = File(p.join(privateDirectory.path, 'library_migration.json'));
    root = LibraryRoot(kind: LibraryRootKind.desktopPath, locator: rootDirectory.path, displayName: 'Library');
    provider = LocalDirectoryLibraryStorageProvider();
  });

  tearDown(() async {
    if (await privateDirectory.exists()) await privateDirectory.delete(recursive: true);
    if (await rootDirectory.exists()) await rootDirectory.delete(recursive: true);
  });

  LegacyLibraryMigrator migrator() => LegacyLibraryMigrator(provider: provider, journalFile: () async => journalFile);

  Future<BookRecord> legacyBook(String name, String contents) async {
    final file = File(p.join(privateDirectory.path, 'books', name));
    await file.parent.create(recursive: true);
    await file.writeAsString(contents, flush: true);
    final digest = (await sha256.bind(file.openRead()).first).toString();
    return BookRecord(
      id: digest,
      title: p.basenameWithoutExtension(name),
      fileName: name,
      format: p.extension(name).substring(1),
      sizeBytes: await file.length(),
      contentSha256: digest,
      localPath: file.path,
      availableOnDeviceIds: const ['device'],
    );
  }

  test('migration copies to root, verifies SHA and leaves legacy source intact', () async {
    final book = await legacyBook('legacy.epub', 'verified bytes');

    final result = await migrator().migrate(target: root, books: [book]);

    expect(result.locationsByBookId[book.id], 'legacy.epub');
    expect(await File(book.localPath!).exists(), isTrue, reason: 'legacy source must not be deleted in Sprint 49A');
    expect(await File(p.join(rootDirectory.path, 'legacy.epub')).readAsString(), 'verified bytes');
    final journal = jsonDecode(await journalFile.readAsString()) as Map<String, dynamic>;
    expect(journal['completed'], isTrue);
  });

  test('interrupted migration resumes idempotently without a second conflicting copy', () async {
    final first = await legacyBook('first.fb2', 'first');
    final second = await legacyBook('second.pdf', 'second');
    var crashed = false;
    final interrupted = LegacyLibraryMigrator(
      provider: provider,
      journalFile: () async => journalFile,
      afterVerified: (bookId) async {
        if (!crashed) {
          crashed = true;
          throw StateError('simulated crash');
        }
      },
    );

    await expectLater(interrupted.migrate(target: root, books: [first, second]), throwsStateError);
    final resumed = await migrator().migrate(target: root, books: [first, second]);

    expect(resumed.locationsByBookId.keys, {first.id, second.id});
    expect(
      (await rootDirectory.list().where((entity) => entity is File).map((entity) => entity as File).toList())
          .map((file) => p.basename(file.path))
          .toSet(),
      {'first.fb2', 'second.pdf'},
    );
  });

  test('wrong destination content never completes migration', () async {
    final book = await legacyBook('book.txt', 'expected');
    final corrupting = _CorruptingProvider(provider);

    await expectLater(
      LegacyLibraryMigrator(
        provider: corrupting,
        journalFile: () async => journalFile,
      ).migrate(target: root, books: [book]),
      throwsA(isA<FileSystemException>()),
    );

    final journal = jsonDecode(await journalFile.readAsString()) as Map<String, dynamic>;
    expect(journal['completed'], isFalse);
    expect(await File(book.localPath!).exists(), isTrue);
  });

  test('crash after copy but before journal update resumes without a duplicate', () async {
    final book = await legacyBook('crash.epub', 'restart safe');
    final copyThenCrash = _CopyThenThrowProvider(provider);

    await expectLater(
      LegacyLibraryMigrator(
        provider: copyThenCrash,
        journalFile: () async => journalFile,
      ).migrate(target: root, books: [book]),
      throwsStateError,
    );
    final resumed = await migrator().migrate(target: root, books: [book]);

    expect(resumed.locationsByBookId[book.id], 'crash.epub');
    expect(await rootDirectory.list().where((entity) => entity is File).length, 1);
    expect(await File(book.localPath!).exists(), isTrue);
  });

  test('corrupted journal is ignored and rebuilt from retained source originals', () async {
    final book = await legacyBook('journal.fb2', 'source survives');
    await journalFile.writeAsString('{broken journal', flush: true);

    final result = await migrator().migrate(target: root, books: [book]);

    expect(result.locationsByBookId[book.id], 'journal.fb2');
    expect(await File(p.join(rootDirectory.path, 'journal.fb2')).readAsString(), 'source survives');
    expect(await File(book.localPath!).exists(), isTrue);
    expect((jsonDecode(await journalFile.readAsString()) as Map<String, dynamic>)['completed'], isTrue);
  });

  test('migration reuses matching historical store-only content after journal loss', () async {
    final book = await legacyBook('legacy.mobi', 'historical bytes');
    await File(p.join(rootDirectory.path, 'already-there.mobi')).writeAsString('historical bytes', flush: true);
    await journalFile.writeAsString('{broken journal', flush: true);

    final result = await migrator().migrate(target: root, books: [book]);

    expect(result.locationsByBookId[book.id], 'already-there.mobi');
    expect(await rootDirectory.list().where((entity) => entity is File).length, 1);
  });

  test('migration never promotes an orphaned partial import as canonical', () async {
    final book = await legacyBook('partial.epub', 'complete bytes');
    final orphan = File(p.join(rootDirectory.path, '.partial.epub.readarc-partial-crash'));
    await orphan.writeAsString('complete bytes', flush: true);

    final result = await migrator().migrate(target: root, books: [book]);

    expect(result.locationsByBookId[book.id], 'partial.epub');
    expect(await File(p.join(rootDirectory.path, 'partial.epub')).readAsString(), 'complete bytes');
    expect(await orphan.exists(), isTrue, reason: '49A does not delete unidentified user-root files');
  });

  test('write failure leaves migration incomplete and source original untouched', () async {
    final book = await legacyBook('disk-full.pdf', 'original');
    final failing = _FailingImportProvider(provider);

    await expectLater(
      LegacyLibraryMigrator(
        provider: failing,
        journalFile: () async => journalFile,
      ).migrate(target: root, books: [book]),
      throwsA(isA<FileSystemException>()),
    );

    expect(await File(book.localPath!).exists(), isTrue);
    final journal = jsonDecode(await journalFile.readAsString()) as Map<String, dynamic>;
    expect(journal['completed'], isFalse);
  });
}

class _CorruptingProvider implements LibraryStorageProvider {
  _CorruptingProvider(this.delegate);
  final LocalDirectoryLibraryStorageProvider delegate;

  @override
  Future<String> importFile(LibraryRoot root, File source, {required String preferredName}) async {
    final relative = await delegate.importFile(root, source, preferredName: preferredName);
    await File(p.join(root.locator, relative)).writeAsString('corrupt', flush: true);
    return relative;
  }

  @override
  Future<LibraryRoot?> chooseRoot() => delegate.chooseRoot();
  @override
  Future<LibraryRoot> refreshRoot(LibraryRoot root) => delegate.refreshRoot(root);
  @override
  Future<bool> containsFile(LibraryRoot root, File source) => delegate.containsFile(root, source);
  @override
  Future<String> contentSha256(LibraryRoot root, LibraryEntry entry) => delegate.contentSha256(root, entry);
  @override
  Future<void> deleteEntry(LibraryRoot root, String relativeLocation) => delegate.deleteEntry(root, relativeLocation);
  @override
  Future<List<LibraryEntry>> listEntries(LibraryRoot root) => delegate.listEntries(root);
  @override
  Future<File> materialize(LibraryRoot root, LibraryEntry entry, Directory cacheDirectory) =>
      delegate.materialize(root, entry, cacheDirectory);
  @override
  Future<LibraryRootStatus> status(LibraryRoot root) => delegate.status(root);
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

class _CopyThenThrowProvider implements LibraryStorageProvider {
  _CopyThenThrowProvider(this.delegate);
  final LocalDirectoryLibraryStorageProvider delegate;
  bool failed = false;

  @override
  Future<String> importFile(LibraryRoot root, File source, {required String preferredName}) async {
    final relative = await delegate.importFile(root, source, preferredName: preferredName);
    if (!failed) {
      failed = true;
      throw StateError('simulated crash before journal update');
    }
    return relative;
  }

  @override
  Future<LibraryRoot?> chooseRoot() => delegate.chooseRoot();
  @override
  Future<LibraryRoot> refreshRoot(LibraryRoot root) => delegate.refreshRoot(root);
  @override
  Future<bool> containsFile(LibraryRoot root, File source) => delegate.containsFile(root, source);
  @override
  Future<String> contentSha256(LibraryRoot root, LibraryEntry entry) => delegate.contentSha256(root, entry);
  @override
  Future<void> deleteEntry(LibraryRoot root, String relativeLocation) => delegate.deleteEntry(root, relativeLocation);
  @override
  Future<List<LibraryEntry>> listEntries(LibraryRoot root) => delegate.listEntries(root);
  @override
  Future<File> materialize(LibraryRoot root, LibraryEntry entry, Directory cacheDirectory) =>
      delegate.materialize(root, entry, cacheDirectory);
  @override
  Future<LibraryRootStatus> status(LibraryRoot root) => delegate.status(root);
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

class _FailingImportProvider extends _CopyThenThrowProvider {
  _FailingImportProvider(super.delegate);

  @override
  Future<String> importFile(LibraryRoot root, File source, {required String preferredName}) {
    throw const FileSystemException('simulated disk full');
  }
}
