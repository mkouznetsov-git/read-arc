import 'dart:convert';
import 'dart:io';

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
}
