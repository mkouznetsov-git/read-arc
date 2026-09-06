part of '../../app/readarc_app.dart';

ReaderDocumentSnapshot _characterizeDjvu(Uint8List bytes) {
  final probe = DjvuEmbeddedProbe.inspect(bytes);
  if (!probe.isDjvu || probe.pageCount <= 0) {
    throw const ReaderParseException('invalid_djvu', 'DJVU FORM container is missing or damaged.');
  }
  final blocks = List<ReaderBlockSnapshot>.generate(
    probe.pageCount,
    (index) => ReaderBlockSnapshot(type: ReaderBlockType.page, text: '', anchors: ['page-${index + 1}']),
    growable: false,
  );
  return ReaderDocumentSnapshot(
    format: ReaderFormat.djvu,
    blocks: blocks,
    anchors: {for (var index = 0; index < probe.pageCount; index++) 'page-${index + 1}': index},
    blockStartChars: List<int>.generate(probe.pageCount, (index) => index, growable: false),
    totalTextChars: probe.pageCount,
    pageCount: probe.pageCount,
  );
}
