import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/book.dart';
import 'library_storage.dart';

class LibraryIndexEntry {
  const LibraryIndexEntry({
    required this.relativeLocation,
    required this.sizeBytes,
    required this.contentSha256,
    required this.availability,
    this.modifiedAt,
  });

  final String relativeLocation;
  final int sizeBytes;
  final DateTime? modifiedAt;
  final String contentSha256;
  final LibraryEntryAvailability availability;

  bool hasSameFingerprint(LibraryEntry entry) {
    if (sizeBytes != entry.sizeBytes) return false;
    if (modifiedAt == null || entry.modifiedAt == null) return false;
    return modifiedAt!.isAtSameMomentAs(entry.modifiedAt!);
  }

  Map<String, dynamic> toJson() => {
    'relativeLocation': relativeLocation,
    'sizeBytes': sizeBytes,
    'modifiedAt': modifiedAt?.toIso8601String(),
    'contentSha256': contentSha256,
    'availability': availability.name,
  };

  factory LibraryIndexEntry.fromJson(Map<String, dynamic> json) => LibraryIndexEntry(
    relativeLocation: json['relativeLocation'] as String,
    sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
    modifiedAt: DateTime.tryParse(json['modifiedAt']?.toString() ?? ''),
    contentSha256: json['contentSha256'] as String,
    availability: LibraryEntryAvailability.values.byName(
      json['availability'] as String? ?? LibraryEntryAvailability.available.name,
    ),
  );
}

class LibraryIndex {
  const LibraryIndex({this.entries = const []});

  final List<LibraryIndexEntry> entries;

  Map<String, dynamic> toJson() => {'schemaVersion': 1, 'entries': entries.map((entry) => entry.toJson()).toList()};

  factory LibraryIndex.fromJson(Map<String, dynamic> json) => LibraryIndex(
    entries: ((json['entries'] as List?) ?? const [])
        .whereType<Map>()
        .map((entry) => LibraryIndexEntry.fromJson(Map<String, dynamic>.from(entry)))
        .toList(),
  );
}

class LibraryScanResult {
  const LibraryScanResult({required this.index, required this.books, required this.hashedFiles});

  final LibraryIndex index;
  final List<BookRecord> books;
  final int hashedFiles;
}

class LibraryIndexStore {
  LibraryIndexStore(this._file);

  final Future<File> Function() _file;

  Future<LibraryIndex> read() async {
    final file = await _file();
    for (final candidate in [file, File('${file.path}.previous')]) {
      if (!await candidate.exists()) continue;
      try {
        final decoded = jsonDecode(await candidate.readAsString());
        if (decoded is Map) return LibraryIndex.fromJson(Map<String, dynamic>.from(decoded));
      } catch (_) {
        // A corrupt cache/index is reproducible from user-owned source files.
      }
    }
    return const LibraryIndex();
  }

  Future<void> write(LibraryIndex index) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(const JsonEncoder.withIndent('  ').convert(index.toJson()), flush: true);
    final previous = File('${file.path}.previous');
    if (await previous.exists()) await previous.delete();
    if (await file.exists()) await file.rename(previous.path);
    await temporary.rename(file.path);
    if (await previous.exists()) await previous.delete();
  }
}

class LibraryScanner {
  const LibraryScanner(this._provider);

  final LibraryStorageProvider _provider;

  Future<LibraryScanResult> scan({
    required LibraryRoot root,
    required LibraryIndex previousIndex,
    required List<BookRecord> previousBooks,
    required String deviceId,
  }) async {
    final rootStatus = await _provider.status(root);
    if (rootStatus != LibraryRootStatus.available) {
      throw LibraryRootAccessException(rootStatus, 'Library root is not available');
    }

    final previousByLocation = {for (final entry in previousIndex.entries) entry.relativeLocation: entry};
    final discovered =
        (await _provider.listEntries(root)).where((entry) => supportedBookExtensions.contains(entry.extension)).toList()
          ..sort((a, b) => a.relativeLocation.compareTo(b.relativeLocation));
    final indexed = <LibraryIndexEntry>[];
    var hashed = 0;

    for (final entry in discovered) {
      final old = previousByLocation[entry.relativeLocation];
      String? contentSha;
      if (old != null && old.hasSameFingerprint(entry)) {
        contentSha = old.contentSha256;
      } else if (entry.availability == LibraryEntryAvailability.available) {
        contentSha = await _provider.contentSha256(root, entry);
        hashed += 1;
      } else if (old != null) {
        // File-provider metadata says the item exists but bytes are not local.
        // Keep its known identity and let materialization happen on demand.
        contentSha = old.contentSha256;
      }
      if (contentSha == null || contentSha.isEmpty) continue;
      indexed.add(
        LibraryIndexEntry(
          relativeLocation: entry.relativeLocation,
          sizeBytes: entry.sizeBytes,
          modifiedAt: entry.modifiedAt,
          contentSha256: contentSha,
          availability: entry.availability,
        ),
      );
    }

    final previousById = {for (final book in previousBooks) book.id: book};
    final locationsBySha = <String, List<LibraryIndexEntry>>{};
    for (final entry in indexed) {
      locationsBySha.putIfAbsent(entry.contentSha256, () => []).add(entry);
    }

    final books = <BookRecord>[];
    for (final item in locationsBySha.entries) {
      final sha = item.key;
      final locations = item.value..sort((a, b) => a.relativeLocation.compareTo(b.relativeLocation));
      final previous = previousById[sha];
      final primary = _choosePrimaryLocation(previous?.relativeLocation, locations);
      final fileName = p.posix.basename(primary.relativeLocation);
      final format = p.posix.extension(fileName).replaceFirst('.', '').toLowerCase();
      final availableOn = <String>{...?previous?.availableOnDeviceIds, deviceId}.toList()..sort();
      books.add(
        previous == null
            ? BookRecord(
                id: sha,
                title: p.posix.basenameWithoutExtension(fileName),
                fileName: fileName,
                format: format,
                sizeBytes: primary.sizeBytes,
                contentSha256: sha,
                relativeLocation: primary.relativeLocation,
                sourceAvailability: primary.availability.name,
                availableOnDeviceIds: availableOn,
                updatedByDeviceId: deviceId,
              )
            : previous.copyWith(
                fileName: fileName,
                format: format,
                sizeBytes: primary.sizeBytes,
                contentSha256: sha,
                relativeLocation: primary.relativeLocation,
                sourceAvailability: primary.availability.name,
                clearLocalPath: true,
                clearDeletedAt: true,
                availableOnDeviceIds: availableOn,
                updatedAt: previous.updatedAt,
              ),
      );
    }

    for (final previous in previousBooks) {
      if (locationsBySha.containsKey(previous.id)) continue;
      if (!previous.isAvailableOnDevice(deviceId) && previous.relativeLocation == null && previous.localPath == null) {
        books.add(previous);
        continue;
      }
      final availableOn = previous.availableOnDeviceIds.where((id) => id != deviceId).toList()..sort();
      books.add(
        previous.copyWith(
          clearRelativeLocation: true,
          clearLocalPath: true,
          sourceAvailability: LibraryEntryAvailability.unavailable.name,
          availableOnDeviceIds: availableOn,
          updatedAt: previous.updatedAt,
        ),
      );
    }

    return LibraryScanResult(
      index: LibraryIndex(entries: indexed),
      books: books,
      hashedFiles: hashed,
    );
  }

  LibraryIndexEntry _choosePrimaryLocation(String? previousLocation, List<LibraryIndexEntry> locations) {
    if (previousLocation != null) {
      for (final entry in locations) {
        if (entry.relativeLocation == previousLocation) return entry;
      }
    }
    return locations.first;
  }
}
