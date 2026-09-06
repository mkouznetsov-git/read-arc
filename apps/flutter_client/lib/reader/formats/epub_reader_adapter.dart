part of '../../app/readarc_app.dart';

ReaderDocumentSnapshot _characterizeEpub(Uint8List bytes, ReaderParseLimits limits) {
  final inspection = _validateZipContainer(bytes, limits);
  if (!inspection.names.contains('META-INF/container.xml') ||
      !inspection.names.any((name) => name.toLowerCase().endsWith('.opf'))) {
    throw const ReaderParseException('invalid_epub', 'EPUB container.xml or package OPF is missing.');
  }
  return _snapshotFromRich(ReaderFormat.epub, _parseEpubDocument(bytes));
}
