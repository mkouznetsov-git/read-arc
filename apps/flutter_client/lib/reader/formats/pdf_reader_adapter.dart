part of '../../app/readarc_app.dart';

ReaderDocumentSnapshot _characterizePdf(Uint8List bytes) {
  if (bytes.length < 8 || !latin1.decode(bytes.take(8).toList(), allowInvalid: true).startsWith('%PDF-1.')) {
    throw const ReaderParseException('invalid_pdf', 'PDF header is missing.');
  }
  final raw = latin1.decode(bytes, allowInvalid: true);
  final pages = RegExp(r'/Type\s*/Page\b').allMatches(raw).length;
  if (pages <= 0 || !raw.contains('%%EOF')) {
    throw const ReaderParseException('invalid_pdf', 'PDF page tree or EOF marker is missing.');
  }
  final text = _extractPdfTextFromBytes(bytes);
  final blocks = <ReaderBlockSnapshot>[];
  final starts = <int>[];
  var cursor = 0;
  if (text.isNotEmpty) {
    for (final paragraph in text.split(RegExp(r'\n{2,}'))) {
      final normalized = paragraph.trim();
      if (normalized.isEmpty) continue;
      starts.add(cursor);
      blocks.add(ReaderBlockSnapshot(type: ReaderBlockType.paragraph, text: normalized));
      cursor += normalized.length + 1;
    }
  }
  return ReaderDocumentSnapshot(
    format: ReaderFormat.pdf,
    blocks: blocks,
    anchors: const {},
    blockStartChars: starts,
    totalTextChars: cursor,
    pageCount: pages,
  );
}
