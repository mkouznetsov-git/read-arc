part of '../../app/readarc_app.dart';

ReaderDocumentSnapshot _characterizeDocx(Uint8List bytes, ReaderParseLimits limits) {
  final inspection = _validateZipContainer(bytes, limits);
  if (!inspection.names.contains('[Content_Types].xml') || !inspection.names.contains('word/document.xml')) {
    throw const ReaderParseException('invalid_docx', 'DOCX content types or word/document.xml is missing.');
  }
  final document = _parseDocxDocument(bytes);
  final explicitBreaks = document.blocks.where((block) => block.plainText == _officePageBreakMarker).length;
  return _snapshotFromRich(ReaderFormat.docx, document, pageCount: explicitBreaks + 1);
}
