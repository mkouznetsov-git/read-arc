import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import '../models/book.dart';
import 'library_storage.dart';
import 'storage_service.dart';

class BookImportService {
  BookImportService(this._storage);

  final StorageService _storage;

  static const supportedExtensions = supportedBookExtensions;

  Future<BookRecord?> pickAndImport() async {
    // Android document providers often do not advertise niche extensions such as
    // .fb2 with a useful MIME type. FileType.custom can therefore hide valid FB2
    // files. On Android we let the picker show all files and validate the
    // extension ourselves after selection.
    final result = await FilePicker.platform.pickFiles(
      type: Platform.isAndroid ? FileType.any : FileType.custom,
      allowedExtensions: Platform.isAndroid ? null : supportedExtensions,
      allowMultiple: false,
      withData: false,
    );
    if (result == null || result.files.isEmpty) return null;
    final path = result.files.single.path;
    if (path == null) return null;
    final extension = p.extension(path).replaceFirst('.', '').toLowerCase();
    if (!supportedExtensions.contains(extension)) {
      throw UnsupportedError('Формат .$extension пока не поддерживается ReadArc');
    }
    return importFile(File(path));
  }

  Future<BookRecord> importFile(File sourceFile) async {
    final exists = await sourceFile.exists();
    if (!exists) throw ArgumentError('File does not exist: ${sourceFile.path}');

    final fileName = p.basename(sourceFile.path);
    final format = p.extension(fileName).replaceFirst('.', '').toLowerCase();
    final digest = await sha256.bind(sourceFile.openRead()).first;
    final sha = digest.toString();

    await _storage.importIntoLibrary(sourceFile, preferredName: fileName);
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
