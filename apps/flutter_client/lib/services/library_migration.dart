import 'dart:convert';
import 'dart:io';

import '../models/book.dart';
import 'library_storage.dart';

class LibraryMigrationResult {
  const LibraryMigrationResult({required this.locationsByBookId, required this.migratedFiles});

  final Map<String, String> locationsByBookId;
  final int migratedFiles;
}

class LegacyLibraryMigrator {
  factory LegacyLibraryMigrator({
    required LibraryStorageProvider provider,
    required Future<File> Function() journalFile,
    Future<void> Function(String bookId)? afterVerified,
  }) => LegacyLibraryMigrator._(provider, journalFile, afterVerified);

  LegacyLibraryMigrator._(this._provider, this._journalFile, this.afterVerified);

  final LibraryStorageProvider _provider;
  final Future<File> Function() _journalFile;
  final Future<void> Function(String bookId)? afterVerified;

  Future<LibraryMigrationResult> migrate({required LibraryRoot target, required List<BookRecord> books}) async {
    final candidates = <BookRecord>[];
    for (final book in books) {
      final path = book.localPath;
      if (path != null && path.isNotEmpty && await File(path).exists()) candidates.add(book);
    }
    if (candidates.isEmpty) return const LibraryMigrationResult(locationsByBookId: {}, migratedFiles: 0);

    final journal = await _loadOrCreateJournal(target, candidates);
    final locations = <String, String>{};
    var migrated = 0;

    for (final book in candidates) {
      final item = journal.items.putIfAbsent(
        book.id,
        () => _MigrationItem(bookId: book.id, sourcePath: book.localPath!, expectedSha256: book.contentSha256),
      );
      if (item.verified && item.relativeLocation != null) {
        if (await _verify(target, item.relativeLocation!, item.expectedSha256)) {
          locations[book.id] = item.relativeLocation!;
          continue;
        }
        item.verified = false;
      }

      final existing = await _findContent(target, item.expectedSha256);
      final relative =
          existing ?? await _provider.importFile(target, File(item.sourcePath), preferredName: book.fileName);
      item.relativeLocation = relative;
      await _save(journal);
      if (!await _verify(target, relative, item.expectedSha256)) {
        throw const FileSystemException('Library migration SHA-256 verification failed');
      }
      item.verified = true;
      locations[book.id] = relative;
      migrated += 1;
      await _save(journal);
      await afterVerified?.call(book.id);
    }

    journal.completed = true;
    await _save(journal);
    return LibraryMigrationResult(locationsByBookId: locations, migratedFiles: migrated);
  }

  Future<String?> _findContent(LibraryRoot root, String expectedSha) async {
    for (final entry in await _provider.listEntries(root)) {
      if (entry.availability == LibraryEntryAvailability.unavailable) continue;
      if (await _provider.contentSha256(root, entry) == expectedSha) return entry.relativeLocation;
    }
    return null;
  }

  Future<bool> _verify(LibraryRoot root, String relativeLocation, String expectedSha) async {
    try {
      final entry = (await _provider.listEntries(root))
          .where((item) => item.relativeLocation == relativeLocation)
          .firstOrNull;
      if (entry == null || entry.availability == LibraryEntryAvailability.unavailable) return false;
      return await _provider.contentSha256(root, entry) == expectedSha;
    } catch (_) {
      return false;
    }
  }

  Future<_MigrationJournal> _loadOrCreateJournal(LibraryRoot target, List<BookRecord> books) async {
    final file = await _journalFile();
    for (final candidate in [file, File('${file.path}.previous')]) {
      if (!await candidate.exists()) continue;
      try {
        final decoded = jsonDecode(await candidate.readAsString());
        final journal = _MigrationJournal.fromJson(Map<String, dynamic>.from(decoded as Map));
        if (journal.target.locator == target.locator && journal.target.kind == target.kind) return journal;
      } catch (_) {
        // A new verified journal is safe because source files are never removed.
      }
    }
    final journal = _MigrationJournal(
      target: target,
      items: {
        for (final book in books)
          book.id: _MigrationItem(bookId: book.id, sourcePath: book.localPath!, expectedSha256: book.contentSha256),
      },
    );
    await _save(journal);
    return journal;
  }

  Future<void> _save(_MigrationJournal journal) async {
    final file = await _journalFile();
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(const JsonEncoder.withIndent('  ').convert(journal.toJson()), flush: true);
    final previous = File('${file.path}.previous');
    if (await previous.exists()) await previous.delete();
    if (await file.exists()) await file.rename(previous.path);
    await temp.rename(file.path);
    if (await previous.exists()) await previous.delete();
  }
}

class _MigrationJournal {
  _MigrationJournal({required this.target, required this.items, this.completed = false});

  final LibraryRoot target;
  final Map<String, _MigrationItem> items;
  bool completed;

  Map<String, dynamic> toJson() => {
    'schemaVersion': 1,
    'target': target.toJson(),
    'completed': completed,
    'items': items.map((key, value) => MapEntry(key, value.toJson())),
  };

  factory _MigrationJournal.fromJson(Map<String, dynamic> json) => _MigrationJournal(
    target: LibraryRoot.fromJson(Map<String, dynamic>.from(json['target'] as Map)),
    completed: json['completed'] == true,
    items: (json['items'] as Map? ?? const {}).map(
      (key, value) => MapEntry(key.toString(), _MigrationItem.fromJson(Map<String, dynamic>.from(value as Map))),
    ),
  );
}

class _MigrationItem {
  _MigrationItem({
    required this.bookId,
    required this.sourcePath,
    required this.expectedSha256,
    this.relativeLocation,
    this.verified = false,
  });

  final String bookId;
  final String sourcePath;
  final String expectedSha256;
  String? relativeLocation;
  bool verified;

  Map<String, dynamic> toJson() => {
    'bookId': bookId,
    'sourcePath': sourcePath,
    'expectedSha256': expectedSha256,
    'relativeLocation': relativeLocation,
    'verified': verified,
  };

  factory _MigrationItem.fromJson(Map<String, dynamic> json) => _MigrationItem(
    bookId: json['bookId'] as String,
    sourcePath: json['sourcePath'] as String,
    expectedSha256: json['expectedSha256'] as String,
    relativeLocation: json['relativeLocation'] as String?,
    verified: json['verified'] == true,
  );
}
