import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

enum LibraryRootKind { desktopPath, androidTreeUri, appleSecurityScopedBookmark }

enum LibraryRootStatus { available, temporarilyUnavailable, permissionLost, missing }

enum LibraryEntryAvailability { available, requiresMaterialization, unavailable }

const supportedBookExtensions = <String>[
  'pdf',
  'doc',
  'docx',
  'txt',
  'fb2',
  'djvu',
  'djv',
  'epub',
  'chm',
  'mobi',
  'azw3',
  'cbz',
  'xps',
];

class LibraryRoot {
  const LibraryRoot({required this.kind, required this.locator, required this.displayName});

  final LibraryRootKind kind;
  final String locator;
  final String displayName;

  Map<String, dynamic> toJson() => {'kind': kind.name, 'locator': locator, 'displayName': displayName};

  factory LibraryRoot.fromJson(Map<String, dynamic> json) => LibraryRoot(
    kind: LibraryRootKind.values.byName(json['kind'] as String),
    locator: json['locator'] as String,
    displayName: json['displayName'] as String? ?? 'ReadArc',
  );
}

class LibraryEntry {
  const LibraryEntry({
    required this.relativeLocation,
    required this.sizeBytes,
    required this.availability,
    this.modifiedAt,
  });

  final String relativeLocation;
  final int sizeBytes;
  final DateTime? modifiedAt;
  final LibraryEntryAvailability availability;

  String get fileName => p.posix.basename(relativeLocation);
  String get extension => p.posix.extension(relativeLocation).replaceFirst('.', '').toLowerCase();

  Map<String, dynamic> toJson() => {
    'relativeLocation': relativeLocation,
    'sizeBytes': sizeBytes,
    'modifiedAt': modifiedAt?.toIso8601String(),
    'availability': availability.name,
  };

  factory LibraryEntry.fromJson(Map<String, dynamic> json) => LibraryEntry(
    relativeLocation: _normalizeRelativeLocation(json['relativeLocation'] as String),
    sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
    modifiedAt: DateTime.tryParse(json['modifiedAt']?.toString() ?? ''),
    availability: LibraryEntryAvailability.values.byName(
      json['availability'] as String? ?? LibraryEntryAvailability.available.name,
    ),
  );
}

class LibraryRootAccessException implements IOException {
  const LibraryRootAccessException(this.status, this.message, [this.cause]);

  final LibraryRootStatus status;
  final String message;
  final Object? cause;

  @override
  String toString() => 'LibraryRootAccessException(${status.name}): $message';
}

abstract interface class LibraryStorageProvider {
  Future<LibraryRoot?> chooseRoot();
  Future<LibraryRootStatus> status(LibraryRoot root);
  Future<List<LibraryEntry>> listEntries(LibraryRoot root);
  Future<String> contentSha256(LibraryRoot root, LibraryEntry entry);
  Future<File> materialize(LibraryRoot root, LibraryEntry entry, Directory cacheDirectory);
  Future<String> importFile(LibraryRoot root, File source, {required String preferredName});
  Future<void> deleteEntry(LibraryRoot root, String relativeLocation);
  Future<bool> containsFile(LibraryRoot root, File source);
}

/// Filesystem implementation used by Windows/Linux and deterministic tests.
/// macOS/iOS use security-scoped bookmarks and Android uses SAF through the
/// method-channel provider below.
class LocalDirectoryLibraryStorageProvider implements LibraryStorageProvider {
  LocalDirectoryLibraryStorageProvider({Future<String?> Function()? chooseDirectory})
    : _chooseDirectory = chooseDirectory;

  final Future<String?> Function()? _chooseDirectory;

  @override
  Future<LibraryRoot?> chooseRoot() async {
    final selected = await _chooseDirectory?.call();
    if (selected == null || selected.trim().isEmpty) return null;
    final directory = Directory(selected);
    if (!await directory.exists()) await directory.create(recursive: true);
    return LibraryRoot(
      kind: LibraryRootKind.desktopPath,
      locator: directory.path,
      displayName: p.basename(directory.path),
    );
  }

  Directory _directory(LibraryRoot root) {
    if (root.kind != LibraryRootKind.desktopPath) {
      throw ArgumentError('Local provider cannot open ${root.kind.name}');
    }
    return Directory(root.locator);
  }

  File _file(LibraryRoot root, String relativeLocation) {
    final normalized = _normalizeRelativeLocation(relativeLocation);
    final rootDirectory = _directory(root);
    final file = File(p.joinAll(<String>[rootDirectory.path, ...p.posix.split(normalized)]));
    final canonicalRoot = p.canonicalize(rootDirectory.absolute.path);
    final canonicalFile = p.canonicalize(file.absolute.path);
    if (!p.isWithin(canonicalRoot, canonicalFile)) throw const FormatException('Library location escapes root');
    return file;
  }

  @override
  Future<LibraryRootStatus> status(LibraryRoot root) async {
    try {
      final directory = _directory(root);
      if (!await directory.exists()) return LibraryRootStatus.missing;
      await directory.list(recursive: false, followLinks: false).take(1).toList();
      return LibraryRootStatus.available;
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode == 13) return LibraryRootStatus.permissionLost;
      return LibraryRootStatus.temporarilyUnavailable;
    }
  }

  @override
  Future<List<LibraryEntry>> listEntries(LibraryRoot root) async {
    final rootDirectory = _directory(root);
    final result = <LibraryEntry>[];
    await for (final entity in rootDirectory.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final stat = await entity.stat();
      result.add(
        LibraryEntry(
          relativeLocation: p.posix.joinAll(p.split(p.relative(entity.path, from: rootDirectory.path))),
          sizeBytes: stat.size,
          modifiedAt: stat.modified.toUtc(),
          availability: LibraryEntryAvailability.available,
        ),
      );
    }
    result.sort((a, b) => a.relativeLocation.compareTo(b.relativeLocation));
    return result;
  }

  @override
  Future<String> contentSha256(LibraryRoot root, LibraryEntry entry) async {
    final file = _file(root, entry.relativeLocation);
    return (await sha256.bind(file.openRead()).first).toString();
  }

  @override
  Future<File> materialize(LibraryRoot root, LibraryEntry entry, Directory cacheDirectory) async {
    final file = _file(root, entry.relativeLocation);
    if (!await file.exists()) {
      throw LibraryRootAccessException(LibraryRootStatus.missing, 'Library file is missing: ${entry.relativeLocation}');
    }
    return file;
  }

  @override
  Future<String> importFile(LibraryRoot root, File source, {required String preferredName}) async {
    if (await containsFile(root, source)) {
      return _normalizeRelativeLocation(p.relative(source.path, from: _directory(root).path));
    }
    final relative = await _unusedName(root, _safeFileName(preferredName));
    final destination = _file(root, relative);
    await destination.parent.create(recursive: true);
    await source.copy(destination.path);
    return relative;
  }

  Future<String> _unusedName(LibraryRoot root, String preferredName) async {
    final extension = p.extension(preferredName);
    final base = p.basenameWithoutExtension(preferredName);
    var candidate = preferredName;
    for (var suffix = 2; await _file(root, candidate).exists(); suffix++) {
      candidate = '$base ($suffix)$extension';
    }
    return candidate;
  }

  @override
  Future<void> deleteEntry(LibraryRoot root, String relativeLocation) async {
    final file = _file(root, relativeLocation);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<bool> containsFile(LibraryRoot root, File source) async {
    final canonicalRoot = p.canonicalize(_directory(root).absolute.path);
    final canonicalSource = p.canonicalize(source.absolute.path);
    return canonicalSource == canonicalRoot || p.isWithin(canonicalRoot, canonicalSource);
  }
}

class PlatformLibraryStorageProvider implements LibraryStorageProvider {
  PlatformLibraryStorageProvider({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('readarc/library_storage');

  final MethodChannel _channel;

  Map<String, dynamic> _rootArgs(LibraryRoot root) => {'root': root.toJson()};

  @override
  Future<LibraryRoot?> chooseRoot() async {
    final value = await _platform(() => _channel.invokeMapMethod<String, dynamic>('chooseRoot'));
    return value == null ? null : LibraryRoot.fromJson(value);
  }

  @override
  Future<LibraryRootStatus> status(LibraryRoot root) async {
    try {
      final value = await _channel.invokeMethod<String>('status', _rootArgs(root));
      return LibraryRootStatus.values.byName(value ?? LibraryRootStatus.temporarilyUnavailable.name);
    } on PlatformException catch (error) {
      return _statusForCode(error.code);
    }
  }

  @override
  Future<List<LibraryEntry>> listEntries(LibraryRoot root) async {
    final raw = await _platform(() => _channel.invokeListMethod<dynamic>('listEntries', _rootArgs(root))) ?? const [];
    return raw.map((item) => LibraryEntry.fromJson(Map<String, dynamic>.from(item as Map))).toList();
  }

  @override
  Future<String> contentSha256(LibraryRoot root, LibraryEntry entry) async {
    final value = await _platform(
      () => _channel.invokeMethod<String>('contentSha256', {
        ..._rootArgs(root),
        'relativeLocation': entry.relativeLocation,
      }),
    );
    if (value == null || value.isEmpty) throw const FileSystemException('Platform did not return SHA-256');
    return value;
  }

  @override
  Future<File> materialize(LibraryRoot root, LibraryEntry entry, Directory cacheDirectory) async {
    await cacheDirectory.create(recursive: true);
    final extension = p.extension(entry.fileName);
    final target = File(
      p.join(cacheDirectory.path, '${base64Url.encode(utf8.encode(entry.relativeLocation))}$extension'),
    );
    final value = await _platform(
      () => _channel.invokeMethod<String>('materialize', {
        ..._rootArgs(root),
        'relativeLocation': entry.relativeLocation,
        'targetPath': target.path,
      }),
    );
    final file = File(value ?? target.path);
    if (!await file.exists()) throw const FileSystemException('Platform did not materialize library file');
    return file;
  }

  @override
  Future<String> importFile(LibraryRoot root, File source, {required String preferredName}) async {
    final value = await _platform(
      () => _channel.invokeMethod<String>('importFile', {
        ..._rootArgs(root),
        'sourcePath': source.path,
        'preferredName': _safeFileName(preferredName),
      }),
    );
    if (value == null || value.isEmpty) throw const FileSystemException('Platform did not import file');
    return _normalizeRelativeLocation(value);
  }

  @override
  Future<void> deleteEntry(LibraryRoot root, String relativeLocation) => _platform(
    () => _channel.invokeMethod<void>('deleteEntry', {..._rootArgs(root), 'relativeLocation': relativeLocation}),
  );

  @override
  Future<bool> containsFile(LibraryRoot root, File source) async =>
      await _platform(
        () => _channel.invokeMethod<bool>('containsFile', {..._rootArgs(root), 'sourcePath': source.path}),
      ) ??
      false;

  Future<T> _platform<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on PlatformException catch (error) {
      throw LibraryRootAccessException(_statusForCode(error.code), error.message ?? error.code, error);
    }
  }

  LibraryRootStatus _statusForCode(String code) {
    for (final status in LibraryRootStatus.values) {
      if (status.name == code) return status;
    }
    return LibraryRootStatus.temporarilyUnavailable;
  }
}

String _normalizeRelativeLocation(String value) {
  final normalized = p.posix.normalize(value.replaceAll('\\', '/')).replaceFirst(RegExp(r'^/+'), '');
  if (normalized.isEmpty || normalized == '.' || normalized == '..' || normalized.startsWith('../')) {
    throw const FormatException('Invalid relative library location');
  }
  return normalized;
}

String _safeFileName(String value) {
  final safe = p.basename(value).replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
  return safe.isEmpty ? 'book' : safe;
}
