part of '../../app/readarc_app.dart';

ReaderDocumentSnapshot _characterizeFb2(Uint8List bytes) {
  final xml = _decodeTextFile(bytes);
  if (!RegExp(r'<FictionBook\b', caseSensitive: false).hasMatch(xml) ||
      !RegExp(r'<body\b', caseSensitive: false).hasMatch(xml)) {
    throw const ReaderParseException('invalid_fb2', 'FB2 FictionBook/body structure is missing.');
  }
  return _snapshotFromRich(ReaderFormat.fb2, _parseFb2Document(xml));
}
