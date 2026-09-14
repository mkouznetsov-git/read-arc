import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

enum LibraryRootKind { desktopPath, androidTreeUri, appleSecurityScopedBookmark }

enum LibraryRootStatus { available, temporarilyUnavailable, permissionLost, missing }

enum LibraryEntryAvailability { available, requiresMaterialization, unavailable }

const readableBookExtensions = <String>['pdf', 'doc', 'docx', 'txt', 'fb2', 'djvu', 'djv', 'epub'];
const storeOnlyBookExtensions = <String>['chm', 'mobi', 'azw3', 'cbz', 'xps'];
const supportedBookExtensions = <String>[...readableBookExtensions, ...storeOnlyBookExtensions];

/// Reserved for portable metadata in Sprint 49B. Sprint 49A must treat this
/// namespace as application metadata, never as user book content.
const reservedLibraryDirectoryName = '.readarc';

/// Import staging names are deliberately not valid book extensions, but legacy
/// migration searches every historical format by hash. Keep partially copied
/// bytes out of both scanning and migration reconciliation.
bool isLibraryImportStagingLocation(String relativeLocation) =>
    p.posix.basename(relativeLocation).contains('.readarc-partial-');

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
  Future<LibraryRoot> refreshRoot(LibraryRoot root);
  Future<LibraryRootStatus> status(LibraryRoot root);
  Future<List<LibraryEntry>> listEntries(LibraryRoot root);
  Future<String> contentSha256(LibraryRoot root, LibraryEntry entry);
  Future<File> materialize(LibraryRoot root, LibraryEntry entry, Directory cacheDirectory);
  Future<String> importFile(LibraryRoot root, File source, {required String preferredName});
  Future<void> deleteEntry(LibraryRoot root, String relativeLocation);
  Future<bool> containsFile(LibraryRoot root, File source);
  Future<Uint8List?> readServiceFile(LibraryRoot root, String relativeLocation);
  Future<List<String>> listServiceFiles(LibraryRoot root, String relativeDirectory);
  Future<void> publishServiceFile(
    LibraryRoot root,
    String relativeLocation,
    Uint8List bytes, {
    bool preservePrevious = true,
  });
}

/// Filesystem implementation used by Windows/Linux and deterministic tests.
/// macOS/iOS use security-scoped bookmarks and Android uses SAF through the
/// method-channel provider below.
class LocalDirectoryLibraryStorageProvider implements LibraryStorageProvider {
  factory LocalDirectoryLibraryStorageProvider({
    Future<String?> Function()? chooseDirectory,
    Future<void> Function(File stagedFile)? afterStagedCopy,
    Future<void> Function(File stagedFile)? afterServiceStaged,
  }) => LocalDirectoryLibraryStorageProvider._(
    chooseDirectory,
    afterStagedCopy,
    afterServiceStaged,
  );

  LocalDirectoryLibraryStorageProvider._(
    this._chooseDirectory,
    this._afterStagedCopy,
    this._afterServiceStaged,
  );

  final Future<String?> Function()? _chooseDirectory;
  final Future<void> Function(File stagedFile)? _afterStagedCopy;
  final Future<void> Function(File stagedFile)? _afterServiceStaged;

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

  @override
  Future<LibraryRoot> refreshRoot(LibraryRoot root) async => root;

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

  Future<void> _rejectSymlinkTraversal(LibraryRoot root, String relativeLocation) async {
    var current = _directory(root).absolute.path;
    for (final segment in p.posix.split(_normalizeRelativeLocation(relativeLocation))) {
      current = p.join(current, segment);
      if (await FileSystemEntity.type(current, followLinks: false) == FileSystemEntityType.link) {
        throw const FormatException('Symbolic links are not supported inside a library root');
      }
    }
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
    await _rejectSymlinkTraversal(root, entry.relativeLocation);
    final file = _file(root, entry.relativeLocation);
    return (await sha256.bind(file.openRead()).first).toString();
  }

  @override
  Future<File> materialize(LibraryRoot root, LibraryEntry entry, Directory cacheDirectory) async {
    await _rejectSymlinkTraversal(root, entry.relativeLocation);
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
    await _rejectSymlinkTraversal(root, relative);
    final staged = File('${destination.path}.readarc-partial-$pid-${DateTime.now().microsecondsSinceEpoch}');
    try {
      await source.copy(staged.path);
      await _afterStagedCopy?.call(staged);
      final sourceSha = (await sha256.bind(source.openRead()).first).toString();
      final stagedSha = (await sha256.bind(staged.openRead()).first).toString();
      if (sourceSha != stagedSha) throw const FileSystemException('Imported copy failed SHA-256 verification');
      if (await destination.exists()) throw const FileSystemException('Import destination appeared during copy');
      await staged.rename(destination.path);
      return relative;
    } finally {
      if (await staged.exists()) await staged.delete();
    }
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
    await _rejectSymlinkTraversal(root, relativeLocation);
    final file = _file(root, relativeLocation);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<bool> containsFile(LibraryRoot root, File source) async {
    if (await FileSystemEntity.type(source.path, followLinks: false) == FileSystemEntityType.link) return false;
    final canonicalRoot = p.canonicalize(_directory(root).absolute.path);
    final canonicalSource = p.canonicalize(source.absolute.path);
    if (!p.isWithin(canonicalRoot, canonicalSource)) return false;
    try {
      await _rejectSymlinkTraversal(root, p.relative(canonicalSource, from: canonicalRoot).replaceAll('\\', '/'));
      return true;
    } on FormatException {
      return false;
    }
  }
  @override
  Future<Uint8List?> readServiceFile(
    LibraryRoot root,
    String relativeLocation,
  ) async {
    final normalized = _normalizeServiceLocation(relativeLocation);
    final rootState = await status(root);
    if (rootState != LibraryRootStatus.available) {
      throw LibraryRootAccessException(
        rootState,
        'Library root is not available for service read',
      );
    }
    await _rejectSymlinkTraversal(root, normalized);
    final file = _file(root, normalized);
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  @override
  Future<List<String>> listServiceFiles(
    LibraryRoot root,
    String relativeDirectory,
  ) async {
    final normalized = _normalizeServiceLocation(relativeDirectory);
    final rootState = await status(root);
    if (rootState != LibraryRootStatus.available) {
      throw LibraryRootAccessException(
        rootState,
        'Library root is not available for service listing',
      );
    }
    await _rejectSymlinkTraversal(root, normalized);
    final directory = Directory(_file(root, normalized).path);
    if (!await directory.exists()) return const <String>[];
    final rootDirectory = _directory(root);
    final result = <String>[];
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      if (await FileSystemEntity.type(entity.path, followLinks: false) ==
          FileSystemEntityType.link) {
        continue;
      }
      final relative = p.posix.joinAll(
        p.split(p.relative(entity.path, from: rootDirectory.path)),
      );
      if (isReservedLibraryLocation(relative)) result.add(relative);
    }
    result.sort();
    return result;
  }

  @override
  Future<void> publishServiceFile(
    LibraryRoot root,
    String relativeLocation,
    Uint8List bytes, {
    bool preservePrevious = true,
  }) async {
    final normalized = _normalizeServiceLocation(relativeLocation);
    final rootState = await status(root);
    if (rootState != LibraryRootStatus.available) {
      throw LibraryRootAccessException(
        rootState,
        'Library root is not available for service write',
      );
    }
    await _rejectSymlinkTraversal(root, normalized);
    final target = _file(root, normalized);
    await target.parent.create(recursive: true);
    final staged = File(
      '${target.path}.readarc-staging-$pid-${DateTime.now().microsecondsSinceEpoch}',
    );
    final previous = File(p.join(target.parent.path, 'previous'));
    var movedCurrent = false;
    var publishedStage = false;
    try {
      await staged.writeAsBytes(bytes, flush: true);
      final expected = sha256.convert(bytes).toString();
      await _afterServiceStaged?.call(staged);
      if (sha256.convert(await staged.readAsBytes()).toString() != expected) {
        throw const FileSystemException(
          'Portable staging verification failed',
        );
      }
      if (preservePrevious && await previous.exists()) {
        await previous.delete();
      }
      if (preservePrevious && await target.exists()) {
        await target.rename(previous.path);
        movedCurrent = true;
      }
      await staged.rename(target.path);
      publishedStage = true;
      if (sha256.convert(await target.readAsBytes()).toString() != expected) {
        throw const FileSystemException(
          'Portable publish verification failed',
        );
      }
    } catch (_) {
      if (publishedStage && await target.exists()) await target.delete();
      if (movedCurrent && await previous.exists()) {
        await previous.rename(target.path);
      }
      rethrow;
    } finally {
      if (await staged.exists()) await staged.delete();
    }
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
  Future<LibraryRoot> refreshRoot(LibraryRoot root) async {
    final value = await _platform(() => _channel.invokeMapMethod<String, dynamic>('refreshRoot', _rootArgs(root)));
    return value == null ? root : LibraryRoot.fromJson(value);
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
    () => _channel.invokeMethod<void>('deleteEntry', {
      ..._rootArgs(root),
      'relativeLocation': _normalizeRelativeLocation(relativeLocation),
    }),
  );

  @override
  Future<bool> containsFile(LibraryRoot root, File source) async {
    final result = await _platform<bool?>(
      () => _channel.invokeMethod<bool>('containsFile', {..._rootArgs(root), 'sourcePath': source.path}),
    );
    return result ?? false;
  }


  @override
  Future<Uint8List?> readServiceFile(
    LibraryRoot root,
    String relativeLocation,
  ) => _platform(
    () => _channel.invokeMethod<Uint8List>('readServiceFile', {
      ..._rootArgs(root),
      'relativeLocation': _normalizeServiceLocation(relativeLocation),
    }),
  );

  @override
  Future<List<String>> listServiceFiles(
    LibraryRoot root,
    String relativeDirectory,
  ) async {
    final result = await _platform(
      () => _channel.invokeListMethod<String>('listServiceFiles', {
        ..._rootArgs(root),
        'relativeLocation': _normalizeServiceLocation(relativeDirectory),
      }),
    );
    return (result ?? const <String>[]).toList()..sort();
  }

  @override
  Future<void> publishServiceFile(
    LibraryRoot root,
    String relativeLocation,
    Uint8List bytes, {
    bool preservePrevious = true,
  }) => _platform(
    () => _channel.invokeMethod<void>('publishServiceFile', {
      ..._rootArgs(root),
      'relativeLocation': _normalizeServiceLocation(relativeLocation),
      'bytes': bytes,
      'preservePrevious': preservePrevious,
    }),
  );

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
  if (value.isEmpty || value.startsWith('/') || value.contains('\u0000')) {
    throw const FormatException('Invalid relative library location');
  }
  final segments = value.split('/');
  if (segments.any((segment) => segment.isEmpty || segment == '.' || segment == '..')) {
    throw const FormatException('Invalid relative library location');
  }
  return p.posix.joinAll(segments);
}

String _normalizeServiceLocation(String value) {
  final normalized = _normalizeRelativeLocation(value);
  if (!isReservedLibraryLocation(normalized)) {
    throw const FormatException('Service files must stay inside .readarc');
  }
  return normalized;
}

bool isReservedLibraryLocation(String relativeLocation) {
  final normalized = _normalizeRelativeLocation(relativeLocation);
  return p.posix.split(normalized).first.toLowerCase() == reservedLibraryDirectoryName;
}

String _safeFileName(String value) {
  final safe = p.basename(value).replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
  return safe.isEmpty ? 'book' : safe;
}
