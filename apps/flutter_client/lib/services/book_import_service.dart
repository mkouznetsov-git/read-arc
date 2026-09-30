import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import '../models/book.dart';
import 'library_storage.dart';
import 'storage_service.dart';

typedef PickBookFile = Future<PlatformFile?> Function();

class BookImportService {
  BookImportService(this._storage, {PickBookFile? pickBookFile}) : _pickBookFile = pickBookFile ?? _pickFromPlatform;

  final StorageService _storage;
  final PickBookFile _pickBookFile;

  // Store-only formats can be discovered and preserved in an existing root,
  // but the ordinary import picker must not advertise them as readable.
  static const supportedExtensions = readableBookExtensions;

  Future<BookRecord?> pickAndImport() async {
    final picked = await _pickBookFile();
    if (picked == null) return null;
    final staged = await _materializePickedFile(picked);
    try {
      return _importFile(staged.file, preferredName: staged.preferredName);
    } finally {
      if (staged.owned && await staged.file.exists()) await staged.file.delete();
    }
  }

  static Future<PlatformFile?> _pickFromPlatform() async {
    // Android document providers often do not advertise niche extensions such as
    // .fb2 with a useful MIME type. FileType.custom can therefore hide valid FB2
    // files. On Android we let the picker show all files and validate the
    // extension ourselves after selection.
    final result = await FilePicker.platform.pickFiles(
      type: Platform.isAndroid ? FileType.any : FileType.custom,
      allowedExtensions: Platform.isAndroid ? null : supportedExtensions,
      allowMultiple: false,
      withData: false,
      // Some Android document providers expose only a content URI and the
      // plugin cannot provide an absolute path. Keep a streaming fallback so
      // those selections are imported instead of being silently ignored.
      withReadStream: true,
    );
    if (result == null || result.files.isEmpty) return null;
    return result.files.single;
  }

  Future<_PickedFile> _materializePickedFile(PlatformFile picked) async {
    final path = picked.path;
    if (path != null && path.trim().isNotEmpty) {
      return _PickedFile(File(path), owned: false, preferredName: picked.name);
    }

    final stream = picked.readStream;
    final bytes = picked.bytes;
    if (stream == null && bytes == null) {
      throw const FileSystemException(
        'Выбранный файл недоступен для чтения. Повторите выбор через системный файловый менеджер.',
      );
    }

    final stagingDirectory = Directory(p.join((await _storage.appDir()).path, 'import_staging'));
    await stagingDirectory.create(recursive: true);
    final extension = p.extension(picked.name).replaceFirst('.', '').toLowerCase();
    final suffix = extension.isEmpty ? '' : '.$extension';
    final staged = File(
      p.join(stagingDirectory.path, 'readarc-import-${DateTime.now().microsecondsSinceEpoch}$suffix'),
    );
    try {
      if (stream != null) {
        final sink = staged.openWrite();
        try {
          await for (final chunk in stream) {
            sink.add(chunk);
          }
        } finally {
          await sink.close();
        }
      } else {
        await staged.writeAsBytes(bytes!, flush: true);
      }
      return _PickedFile(staged, owned: true, preferredName: picked.name);
    } catch (_) {
      if (await staged.exists()) await staged.delete();
      rethrow;
    }
  }

  Future<BookRecord> importFile(File sourceFile) async {
    return _importFile(sourceFile, preferredName: p.basename(sourceFile.path));
  }

  Future<BookRecord> _importFile(File sourceFile, {required String preferredName}) async {
    final exists = await sourceFile.exists();
    if (!exists) throw ArgumentError('File does not exist: ${sourceFile.path}');

    final fileName = p.basename(preferredName);
    final format = p.extension(fileName).replaceFirst('.', '').toLowerCase();
    if (!supportedExtensions.contains(format)) {
      throw UnsupportedError('Формат .$format пока не поддерживается ReadArc');
    }
    final digest = await sha256.bind(sourceFile.openRead()).first;
    final sha = digest.toString();

    await _storage.importIntoLibrary(sourceFile, preferredName: fileName, expectedSha256: sha);
    final manifest = await _storage.loadManifest();
    final imported = manifest.books.where((candidate) => candidate.id == sha).firstOrNull;
    if (imported == null) {
      throw const FileSystemException('Импортированный файл не найден scanner-ом');
    }
    // Scanner owns source location and identity; existing progress/bookmarks
    // remain untouched when the same content is imported again.
    return imported;
  }
}

class _PickedFile {
  const _PickedFile(this.file, {required this.owned, required this.preferredName});

  final File file;
  final bool owned;
  final String preferredName;
}
