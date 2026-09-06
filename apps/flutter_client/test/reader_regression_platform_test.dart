import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:readarc/app/readarc_app.dart';

Uint8List _fixture(String name) => File('test/fixtures/$name').readAsBytesSync();

ReaderDocumentSnapshot _snapshot(String text) => ReaderDocumentSnapshot(
  format: ReaderFormat.txt,
  blocks: [ReaderBlockSnapshot(type: ReaderBlockType.paragraph, text: text)],
  anchors: const {},
  blockStartChars: const [0],
  totalTextChars: text.length,
  pageCount: 0,
);

Uint8List _declaredZipEntry({
  required String name,
  required int compressed,
  required int uncompressed,
  Uint8List? prefix,
}) {
  final nameBytes = utf8.encode(name);
  final centralDirectoryOffset = prefix?.length ?? 0;
  final centralDirectorySize = 46 + nameBytes.length;
  final eocdOffset = centralDirectoryOffset + centralDirectorySize;
  final bytes = Uint8List(eocdOffset + 22);
  if (prefix != null) bytes.setRange(0, prefix.length, prefix);
  final data = ByteData.sublistView(bytes);
  data.setUint32(centralDirectoryOffset, 0x02014b50, Endian.little);
  data.setUint32(centralDirectoryOffset + 20, compressed, Endian.little);
  data.setUint32(centralDirectoryOffset + 24, uncompressed, Endian.little);
  data.setUint16(centralDirectoryOffset + 28, nameBytes.length, Endian.little);
  bytes.setRange(centralDirectoryOffset + 46, eocdOffset, nameBytes);
  data.setUint32(eocdOffset, 0x06054b50, Endian.little);
  data.setUint16(eocdOffset + 8, 1, Endian.little);
  data.setUint16(eocdOffset + 10, 1, Endian.little);
  data.setUint32(eocdOffset + 12, centralDirectorySize, Endian.little);
  data.setUint32(eocdOffset + 16, centralDirectoryOffset, Endian.little);
  return bytes;
}

void main() {
  group('reader characterization fixtures', () {
    test('TXT preserves paragraphs, text and locator', () async {
      final document = await ReaderRegressionPlatform.parse(ReaderFormat.txt, _fixture('txt_characterization.txt'));
      expect(document.blocks, hasLength(3));
      expect(document.plainText, contains('Первый абзац'));
      final saved = ReaderLocator.atBlock(document, 2);
      final restored = ReaderLocator.restore(document, saved.toJsonString());
      expect(restored.blockIndex, 2);
      expect(restored.anchorChar, saved.anchorChar);
    });

    test('FB2 preserves title, blocks and stable locator', () async {
      final document = await ReaderRegressionPlatform.parse(ReaderFormat.fb2, _fixture('fb2_characterization.fb2'));
      expect(document.blocks.first.type, ReaderBlockType.title);
      expect(document.blocks.first.text, 'Глава первая');
      expect(document.plainText, contains('Второй абзац'));
      final restored = ReaderLocator.restore(
        document,
        jsonEncode({'type': 'fb2-unit-anchor-v4', 'anchorChar': document.blockStartChars.last}),
      );
      expect(restored.blockIndex, document.blocks.length - 1);
    });

    test('EPUB preserves spine text, hrefs and target anchors', () async {
      final document = await ReaderRegressionPlatform.parse(ReaderFormat.epub, _fixture('epub_characterization.epub'));
      expect(document.plainText, contains('EPUB chapter one'));
      expect(document.blocks.expand((block) => block.hrefs), contains('OEBPS/chapter.xhtml#target'));
      expect(document.anchors['OEBPS/chapter.xhtml#target'], isNotNull);
      final target = document.anchors['OEBPS/chapter.xhtml#target']!;
      expect(
        ReaderLocator.restore(document, ReaderLocator.atBlock(document, target).toJsonString()).blockIndex,
        target,
      );
    });

    test('PDF preserves selectable text, page count and page locator', () async {
      final document = await ReaderRegressionPlatform.parse(ReaderFormat.pdf, _fixture('pdf_characterization.pdf'));
      expect(document.pageCount, 2);
      expect(document.plainText, contains('stable selectable text'));
      final restored = ReaderLocator.restore(document, jsonEncode({'type': 'pdf-page-v1', 'page': 2}));
      expect(restored.page, 2);
      expect(restored.progressPercent, 100);
    });

    test('DOCX preserves paragraphs, table cells, page breaks and locator', () async {
      final document = await ReaderRegressionPlatform.parse(ReaderFormat.docx, _fixture('docx_characterization.docx'));
      expect(document.plainText, contains('First DOCX paragraph'));
      final table = document.blocks.singleWhere((block) => block.type == ReaderBlockType.table);
      expect(table.tableRows, [
        ['Column A', 'Column B'],
        ['Value 1', 'Value 2'],
      ]);
      expect(document.pageCount, 2);
      final saved = ReaderLocator.atBlock(document, document.blocks.length - 1);
      expect(ReaderLocator.restore(document, saved.toJsonString()).blockIndex, saved.blockIndex);
    });

    test('DJVU preserves detected pages and page anchors', () async {
      final document = await ReaderRegressionPlatform.parse(ReaderFormat.djvu, _fixture('djvu_characterization.djvu'));
      expect(document.pageCount, 2);
      expect(document.blocks.map((block) => block.type), everyElement(ReaderBlockType.page));
      expect(document.anchors, {'page-1': 0, 'page-2': 1});
      expect(ReaderLocator.restore(document, jsonEncode({'type': 'djvu-page-v2', 'page': 2})).page, 2);
    });
  });

  group('reader limits and failure containment', () {
    test('rejects every damaged fixture with a controlled parser error', () async {
      for (final format in ReaderFormat.values) {
        final damaged = format == ReaderFormat.txt
            ? Uint8List.fromList(List<int>.filled(64, 0))
            : Uint8List.fromList('damaged ${format.name}'.codeUnits);
        await expectLater(
          ReaderRegressionPlatform.parse(format, damaged),
          throwsA(isA<ReaderParseException>()),
          reason: '${format.name} damage must not become an empty successful document',
        );
      }
    });

    test('rejects oversized input before parsing', () async {
      await expectLater(
        ReaderRegressionPlatform.parse(
          ReaderFormat.txt,
          Uint8List(2048),
          limits: const ReaderParseLimits(maxInputBytes: 1024),
        ),
        throwsA(isA<ReaderParseException>().having((error) => error.code, 'code', 'input_too_large')),
      );
    });

    test('rejects declared ZIP bomb before archive decompression', () async {
      final bomb = _declaredZipEntry(name: 'OEBPS/chapter.xhtml', compressed: 1, uncompressed: 1024 * 1024);
      await expectLater(
        ReaderRegressionPlatform.parse(
          ReaderFormat.epub,
          bomb,
          limits: const ReaderParseLimits(maxZipEntryBytes: 4096),
        ),
        throwsA(isA<ReaderParseException>().having((error) => error.code, 'code', 'zip_entry_too_large')),
      );
    });

    test('rejects traversal paths in ZIP metadata', () async {
      final traversal = _declaredZipEntry(name: '../manifest.opf', compressed: 20, uncompressed: 20);
      await expectLater(
        ReaderRegressionPlatform.parse(ReaderFormat.epub, traversal),
        throwsA(isA<ReaderParseException>().having((error) => error.code, 'code', 'unsafe_zip_path')),
      );
    });

    test('does not scan compressed payload for false central-directory signatures', () async {
      final payload = Uint8List(46)..setAll(0, [0x50, 0x4b, 0x01, 0x02]);
      final archive = _declaredZipEntry(name: 'payload.bin', compressed: 4, uncompressed: 4, prefix: payload);
      await expectLater(
        ReaderRegressionPlatform.parse(ReaderFormat.epub, archive),
        throwsA(isA<ReaderParseException>().having((error) => error.code, 'code', 'invalid_epub')),
      );
    });

    test('large TXT parses in background with bounded output', () async {
      const paragraph = 'Large ReadArc paragraph keeps semantic parsing responsive and deterministic.\n\n';
      final bytes = Uint8List.fromList(utf8.encode(paragraph * 15000));
      final document = await ReaderRegressionPlatform.parse(
        ReaderFormat.txt,
        bytes,
      ).timeout(const Duration(seconds: 20));
      expect(document.blocks.length, 15000);
      expect(document.totalTextChars, greaterThan(1000000));
    });

    test('active background parse can be cancelled', () async {
      final job = ReaderRegressionPlatform.startParse(ReaderFormat.txt, Uint8List(8 * 1024 * 1024));
      job.cancel();
      await expectLater(job.result, throwsA(isA<ReaderParseCancelledException>()));
    });
  });

  group('lazy parsing and bounded cache', () {
    test('does not parse until the document is materialized', () async {
      final cache = ReaderDocumentCache();
      var calls = 0;
      final handle = cache.open('lazy', () async {
        calls += 1;
        return _snapshot('lazy');
      });
      expect(calls, 0);
      expect((await handle.materialize()).plainText, 'lazy');
      expect(calls, 1);
      expect((await handle.materialize()).plainText, 'lazy');
      expect(calls, 1);
    });

    test('evicts least recently used documents at the configured bound', () async {
      final cache = ReaderDocumentCache(maxEntries: 1);
      var firstLoads = 0;
      Future<ReaderDocumentSnapshot> firstLoader() async {
        firstLoads += 1;
        return _snapshot('first');
      }

      await cache.open('first', firstLoader).materialize();
      await cache.open('second', () async => _snapshot('second')).materialize();
      await cache.open('first', firstLoader).materialize();
      expect(cache.length, 1);
      expect(firstLoads, 2);
    });
  });
}
