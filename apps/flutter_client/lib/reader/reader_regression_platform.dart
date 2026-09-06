part of '../app/readarc_app.dart';

/// Formats protected by the reader characterization suite.
enum ReaderFormat { txt, fb2, epub, pdf, docx, djvu }

enum ReaderBlockType { paragraph, title, image, table, page }

class ReaderParseLimits {
  const ReaderParseLimits({
    this.maxInputBytes = 256 * 1024 * 1024,
    this.maxZipEntries = 4096,
    this.maxZipEntryBytes = 64 * 1024 * 1024,
    this.maxZipExpandedBytes = 512 * 1024 * 1024,
    this.maxCompressionRatio = 200,
    this.maxBlocks = 250000,
    this.maxTextChars = 100000000,
  });

  final int maxInputBytes;
  final int maxZipEntries;
  final int maxZipEntryBytes;
  final int maxZipExpandedBytes;
  final int maxCompressionRatio;
  final int maxBlocks;
  final int maxTextChars;

  Map<String, int> toJson() => {
    'maxInputBytes': maxInputBytes,
    'maxZipEntries': maxZipEntries,
    'maxZipEntryBytes': maxZipEntryBytes,
    'maxZipExpandedBytes': maxZipExpandedBytes,
    'maxCompressionRatio': maxCompressionRatio,
    'maxBlocks': maxBlocks,
    'maxTextChars': maxTextChars,
  };

  factory ReaderParseLimits.fromJson(Map<Object?, Object?> json) => ReaderParseLimits(
    maxInputBytes: (json['maxInputBytes'] as num).toInt(),
    maxZipEntries: (json['maxZipEntries'] as num).toInt(),
    maxZipEntryBytes: (json['maxZipEntryBytes'] as num).toInt(),
    maxZipExpandedBytes: (json['maxZipExpandedBytes'] as num).toInt(),
    maxCompressionRatio: (json['maxCompressionRatio'] as num).toInt(),
    maxBlocks: (json['maxBlocks'] as num).toInt(),
    maxTextChars: (json['maxTextChars'] as num).toInt(),
  );
}

class ReaderParseException implements Exception {
  const ReaderParseException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'ReaderParseException($code): $message';
}

class ReaderParseCancelledException extends ReaderParseException {
  const ReaderParseCancelledException() : super('cancelled', 'Reader parsing was cancelled.');
}

class ReaderBlockSnapshot {
  const ReaderBlockSnapshot({
    required this.type,
    this.text = '',
    this.anchors = const [],
    this.hrefs = const [],
    this.tableRows = const [],
    this.bold = false,
    this.italic = false,
  });

  final ReaderBlockType type;
  final String text;
  final List<String> anchors;
  final List<String> hrefs;
  final List<List<String>> tableRows;
  final bool bold;
  final bool italic;

  Map<String, Object?> toJson() => {
    'type': type.name,
    'text': text,
    'anchors': anchors,
    'hrefs': hrefs,
    'tableRows': tableRows,
    'bold': bold,
    'italic': italic,
  };

  factory ReaderBlockSnapshot.fromJson(Map<Object?, Object?> json) => ReaderBlockSnapshot(
    type: ReaderBlockType.values.byName(json['type']! as String),
    text: json['text']! as String,
    anchors: List<String>.from(json['anchors']! as List),
    hrefs: List<String>.from(json['hrefs']! as List),
    tableRows: (json['tableRows']! as List).map((row) => List<String>.from(row as List)).toList(growable: false),
    bold: json['bold']! as bool,
    italic: json['italic']! as bool,
  );
}

class ReaderDocumentSnapshot {
  ReaderDocumentSnapshot({
    required this.format,
    required List<ReaderBlockSnapshot> blocks,
    required Map<String, int> anchors,
    required List<int> blockStartChars,
    required this.totalTextChars,
    required this.pageCount,
  }) : blocks = List.unmodifiable(blocks),
       anchors = Map.unmodifiable(anchors),
       blockStartChars = List.unmodifiable(blockStartChars);

  final ReaderFormat format;
  final List<ReaderBlockSnapshot> blocks;
  final Map<String, int> anchors;
  final List<int> blockStartChars;
  final int totalTextChars;
  final int pageCount;

  String get plainText => blocks.map((block) => block.text).where((text) => text.trim().isNotEmpty).join('\n');

  ReaderBlockSnapshot blockAt(int index) => blocks[index];

  Map<String, Object?> toJson() => {
    'format': format.name,
    'blocks': blocks.map((block) => block.toJson()).toList(growable: false),
    'anchors': anchors,
    'blockStartChars': blockStartChars,
    'totalTextChars': totalTextChars,
    'pageCount': pageCount,
  };

  factory ReaderDocumentSnapshot.fromJson(Map<Object?, Object?> json) => ReaderDocumentSnapshot(
    format: ReaderFormat.values.byName(json['format']! as String),
    blocks: (json['blocks']! as List)
        .map((block) => ReaderBlockSnapshot.fromJson(block as Map<Object?, Object?>))
        .toList(growable: false),
    anchors: Map<String, int>.from(json['anchors']! as Map),
    blockStartChars: List<int>.from(json['blockStartChars']! as List),
    totalTextChars: (json['totalTextChars']! as num).toInt(),
    pageCount: (json['pageCount']! as num).toInt(),
  );
}

class ReaderLocator {
  const ReaderLocator({
    required this.type,
    required this.blockIndex,
    required this.anchorChar,
    required this.progressPercent,
    this.page,
  });

  final String type;
  final int blockIndex;
  final int anchorChar;
  final double progressPercent;
  final int? page;

  String toJsonString() => jsonEncode({
    'type': type,
    'blockIndex': blockIndex,
    'anchorChar': anchorChar,
    'progressPercent': progressPercent,
    if (page != null) 'page': page,
  });

  static ReaderLocator atBlock(ReaderDocumentSnapshot document, int blockIndex) {
    if (document.blocks.isEmpty) {
      return ReaderLocator(
        type: '${document.format.name}-block-anchor-v1',
        blockIndex: 0,
        anchorChar: 0,
        progressPercent: 0,
      );
    }
    final safe = blockIndex.clamp(0, document.blocks.length - 1).toInt();
    final anchorChar = document.blockStartChars.isEmpty ? 0 : document.blockStartChars[safe];
    final progress = document.totalTextChars <= 0
        ? 0.0
        : ((anchorChar / document.totalTextChars) * 100).clamp(0.0, 100.0).toDouble();
    return ReaderLocator(
      type: '${document.format.name}-block-anchor-v1',
      blockIndex: safe,
      anchorChar: anchorChar,
      progressPercent: progress,
    );
  }

  static ReaderLocator restore(ReaderDocumentSnapshot document, String encoded, {double fallbackProgressPercent = 0}) {
    if (document.format == ReaderFormat.pdf || document.format == ReaderFormat.djvu) {
      return _restorePageLocator(document, encoded, fallbackProgressPercent);
    }
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is Map) {
        final anchorChar = (decoded['anchorChar'] as num?)?.round();
        if (anchorChar != null && document.blockStartChars.isNotEmpty) {
          final block = _blockForAnchor(document.blockStartChars, anchorChar);
          return atBlock(document, block);
        }
        final block = (decoded['blockIndex'] as num?)?.round();
        if (block != null) return atBlock(document, block);
        final progress = (decoded['progressPercent'] as num?)?.toDouble();
        if (progress != null) return _atProgress(document, progress);
      }
    } catch (_) {}
    return _atProgress(document, fallbackProgressPercent);
  }

  static ReaderLocator _atProgress(ReaderDocumentSnapshot document, double progress) {
    if (document.blocks.isEmpty) return atBlock(document, 0);
    final fraction = progress.clamp(0.0, 100.0) / 100.0;
    final targetChar = (document.totalTextChars * fraction).round();
    return atBlock(document, _blockForAnchor(document.blockStartChars, targetChar));
  }

  static ReaderLocator _restorePageLocator(ReaderDocumentSnapshot document, String encoded, double fallbackProgress) {
    final pages = document.pageCount <= 0 ? 1 : document.pageCount;
    var page = pages <= 1 ? 1 : (1 + ((fallbackProgress.clamp(0, 100) / 100) * (pages - 1)).round());
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is Map) page = (decoded['page'] as num?)?.round() ?? page;
    } catch (_) {}
    page = page.clamp(1, pages).toInt();
    final progress = pages <= 1 ? 0.0 : ((page - 1) / (pages - 1)) * 100;
    return ReaderLocator(
      type: '${document.format.name}-page-v1',
      blockIndex: page - 1,
      anchorChar: 0,
      progressPercent: progress,
      page: page,
    );
  }

  static int _blockForAnchor(List<int> starts, int anchorChar) {
    if (starts.isEmpty) return 0;
    var low = 0;
    var high = starts.length - 1;
    while (low <= high) {
      final mid = low + ((high - low) >> 1);
      if (starts[mid] <= anchorChar) {
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return high.clamp(0, starts.length - 1).toInt();
  }
}

/// Cancellable background parse. Heavy format work never runs in the UI isolate.
class ReaderParseJob {
  ReaderParseJob._(this._format, this._bytes, this._limits) {
    unawaited(_start());
  }

  final ReaderFormat _format;
  final Uint8List _bytes;
  final ReaderParseLimits _limits;
  final Completer<ReaderDocumentSnapshot> _completer = Completer<ReaderDocumentSnapshot>();
  Isolate? _isolate;
  ReceivePort? _receivePort;
  bool _cancelled = false;

  Future<ReaderDocumentSnapshot> get result => _completer.future;

  Future<void> _start() async {
    if (_cancelled) return;
    final port = ReceivePort();
    _receivePort = port;
    try {
      _isolate = await Isolate.spawn<List<Object?>>(_readerParseWorker, [
        port.sendPort,
        _format.name,
        TransferableTypedData.fromList([_bytes]),
        _limits.toJson(),
      ]);
      if (_cancelled) {
        _isolate?.kill(priority: Isolate.immediate);
        return;
      }
      final response = await port.first;
      if (_cancelled || _completer.isCompleted) return;
      if (response is Map && response['ok'] == true) {
        _completer.complete(ReaderDocumentSnapshot.fromJson(response['document'] as Map<Object?, Object?>));
      } else if (response is Map) {
        _completer.completeError(
          ReaderParseException(
            response['code'] as String? ?? 'parse_failed',
            response['message'] as String? ?? 'Unknown reader parser failure.',
          ),
        );
      } else {
        _completer.completeError(const ReaderParseException('invalid_worker_response', 'Invalid parser response.'));
      }
    } catch (error, stackTrace) {
      if (!_cancelled && !_completer.isCompleted) _completer.completeError(error, stackTrace);
    } finally {
      port.close();
      _receivePort = null;
      _isolate = null;
    }
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _isolate?.kill(priority: Isolate.immediate);
    _receivePort?.close();
    if (!_completer.isCompleted) _completer.completeError(const ReaderParseCancelledException());
  }
}

class ReaderRegressionPlatform {
  const ReaderRegressionPlatform._();

  static ReaderParseJob startParse(
    ReaderFormat format,
    Uint8List bytes, {
    ReaderParseLimits limits = const ReaderParseLimits(),
  }) => ReaderParseJob._(format, bytes, limits);

  static Future<ReaderDocumentSnapshot> parse(
    ReaderFormat format,
    Uint8List bytes, {
    ReaderParseLimits limits = const ReaderParseLimits(),
  }) => startParse(format, bytes, limits: limits).result;
}

/// Lazy materialization with a small LRU. Parsed books cannot accumulate without
/// bound when the user moves through a large library.
class ReaderDocumentCache {
  ReaderDocumentCache({this.maxEntries = 3, this.maxEstimatedBytes = 64 * 1024 * 1024});

  final int maxEntries;
  final int maxEstimatedBytes;
  final Map<String, ReaderDocumentSnapshot> _entries = {};
  final List<String> _order = [];
  int _estimatedBytes = 0;

  int get length => _entries.length;

  ReaderDocumentHandle open(String key, Future<ReaderDocumentSnapshot> Function() loader) {
    return ReaderDocumentHandle._(this, key, loader);
  }

  ReaderDocumentSnapshot? _get(String key) {
    final value = _entries[key];
    if (value == null) return null;
    _order.remove(key);
    _order.add(key);
    return value;
  }

  void _put(String key, ReaderDocumentSnapshot value) {
    final old = _entries.remove(key);
    if (old != null) _estimatedBytes -= _estimate(old);
    _order.remove(key);
    _entries[key] = value;
    _order.add(key);
    _estimatedBytes += _estimate(value);
    while (_entries.length > maxEntries || _estimatedBytes > maxEstimatedBytes) {
      if (_order.isEmpty) break;
      final oldest = _order.removeAt(0);
      final removed = _entries.remove(oldest);
      if (removed != null) _estimatedBytes -= _estimate(removed);
    }
  }

  int _estimate(ReaderDocumentSnapshot document) {
    return document.totalTextChars * 2 + document.blocks.length * 96;
  }
}

class ReaderDocumentHandle {
  ReaderDocumentHandle._(this._cache, this._key, this._loader);

  final ReaderDocumentCache _cache;
  final String _key;
  final Future<ReaderDocumentSnapshot> Function() _loader;
  Future<ReaderDocumentSnapshot>? _pending;

  Future<ReaderDocumentSnapshot> materialize() {
    final cached = _cache._get(_key);
    if (cached != null) return Future.value(cached);
    return _pending ??= _loader().then((document) {
      _cache._put(_key, document);
      return document;
    });
  }
}

void _readerParseWorker(List<Object?> request) {
  unawaited(_readerParseWorkerAsync(request));
}

Future<void> _readerParseWorkerAsync(List<Object?> request) async {
  final sendPort = request[0]! as SendPort;
  try {
    final format = ReaderFormat.values.byName(request[1]! as String);
    final bytes = (request[2]! as TransferableTypedData).materialize().asUint8List();
    final limits = ReaderParseLimits.fromJson(request[3]! as Map<Object?, Object?>);
    final document = _characterizeReaderBytes(format, bytes, limits);
    sendPort.send({'ok': true, 'document': document.toJson()});
  } on ReaderParseException catch (error) {
    sendPort.send({'ok': false, 'code': error.code, 'message': error.message});
  } catch (error, stackTrace) {
    sendPort.send({'ok': false, 'code': 'parse_failed', 'message': '$error\n$stackTrace'});
  }
}

ReaderDocumentSnapshot _characterizeReaderBytes(ReaderFormat format, Uint8List bytes, ReaderParseLimits limits) {
  if (bytes.length > limits.maxInputBytes) {
    throw ReaderParseException('input_too_large', 'Input is ${bytes.length} bytes; limit is ${limits.maxInputBytes}.');
  }
  final document = switch (format) {
    ReaderFormat.txt => _characterizeTxt(bytes),
    ReaderFormat.fb2 => _characterizeFb2(bytes),
    ReaderFormat.epub => _characterizeEpub(bytes, limits),
    ReaderFormat.pdf => _characterizePdf(bytes),
    ReaderFormat.docx => _characterizeDocx(bytes, limits),
    ReaderFormat.djvu => _characterizeDjvu(bytes),
  };
  if (document.blocks.length > limits.maxBlocks) {
    throw ReaderParseException('too_many_blocks', 'Document produced ${document.blocks.length} blocks.');
  }
  if (document.totalTextChars > limits.maxTextChars) {
    throw ReaderParseException('text_too_large', 'Document produced ${document.totalTextChars} text characters.');
  }
  return document;
}

ReaderDocumentSnapshot _snapshotFromRich(ReaderFormat format, _Fb2Document source, {int pageCount = 0}) {
  final blocks = source.blocks
      .map((block) {
        final type = switch (block.kind) {
          _Fb2BlockKind.paragraph => ReaderBlockType.paragraph,
          _Fb2BlockKind.title => ReaderBlockType.title,
          _Fb2BlockKind.image => ReaderBlockType.image,
          _Fb2BlockKind.table => ReaderBlockType.table,
        };
        return ReaderBlockSnapshot(
          type: type,
          text: block.plainText == _officePageBreakMarker ? '' : block.plainText,
          anchors: List.unmodifiable(block.anchors),
          hrefs: block.inlines.map((inline) => inline.href).whereType<String>().toSet().toList(growable: false),
          tableRows: block.tableRows.map((row) => List<String>.unmodifiable(row)).toList(growable: false),
          bold: block.officeFormat.bold || block.inlines.any((inline) => inline.bold),
          italic: block.officeFormat.italic || block.inlines.any((inline) => inline.italic),
        );
      })
      .toList(growable: false);
  return ReaderDocumentSnapshot(
    format: format,
    blocks: blocks,
    anchors: source.linkTargets,
    blockStartChars: source.blockStartChars,
    totalTextChars: source.totalTextChars,
    pageCount: pageCount,
  );
}

class _ZipInspection {
  const _ZipInspection(this.names, this.expandedBytes);

  final Set<String> names;
  final int expandedBytes;
}

_ZipInspection _validateZipContainer(Uint8List bytes, [ReaderParseLimits limits = const ReaderParseLimits()]) {
  if (bytes.length > limits.maxInputBytes) {
    throw ReaderParseException('input_too_large', 'ZIP input exceeds ${limits.maxInputBytes} bytes.');
  }
  final eocd = _findZipEndOfCentralDirectory(bytes);
  if (eocd < 0) {
    throw const ReaderParseException('invalid_zip', 'ZIP end-of-central-directory record is missing.');
  }
  final diskNumber = _readLe16(bytes, eocd + 4);
  final directoryDisk = _readLe16(bytes, eocd + 6);
  final entriesOnDisk = _readLe16(bytes, eocd + 8);
  final expectedEntries = _readLe16(bytes, eocd + 10);
  final directorySize = _readLe32(bytes, eocd + 12);
  final directoryOffset = _readLe32(bytes, eocd + 16);
  final commentLength = _readLe16(bytes, eocd + 20);
  if (eocd + 22 + commentLength != bytes.length) {
    throw const ReaderParseException('invalid_zip_directory', 'Malformed ZIP end record or comment length.');
  }
  if (diskNumber != 0 || directoryDisk != 0 || entriesOnDisk != expectedEntries) {
    throw const ReaderParseException('multi_disk_zip_not_supported', 'Multi-disk ZIP containers are not accepted.');
  }
  if (expectedEntries == 0xffff || directorySize == 0xffffffff || directoryOffset == 0xffffffff) {
    throw const ReaderParseException('zip64_not_supported', 'ZIP64 containers are not accepted by the reader parser.');
  }
  if (expectedEntries == 0 ||
      expectedEntries > limits.maxZipEntries ||
      directoryOffset + directorySize != eocd ||
      directoryOffset > bytes.length) {
    throw const ReaderParseException('invalid_zip_directory', 'ZIP central directory bounds are invalid.');
  }
  final names = <String>{};
  var entries = 0;
  var expanded = 0;
  var offset = directoryOffset;
  final directoryEnd = directoryOffset + directorySize;
  while (offset < directoryEnd) {
    if (offset + 46 > directoryEnd || _readLe32(bytes, offset) != 0x02014b50) {
      throw const ReaderParseException('invalid_zip_directory', 'Malformed ZIP central directory entry.');
    }
    final compressed = _readLe32(bytes, offset + 20);
    final uncompressed = _readLe32(bytes, offset + 24);
    final nameLength = _readLe16(bytes, offset + 28);
    final extraLength = _readLe16(bytes, offset + 30);
    final commentLength = _readLe16(bytes, offset + 32);
    final end = offset + 46 + nameLength + extraLength + commentLength;
    if (nameLength <= 0 || nameLength > 512 || end > directoryEnd) {
      throw const ReaderParseException('invalid_zip_directory', 'Malformed ZIP central directory.');
    }
    final name = utf8
        .decode(bytes.sublist(offset + 46, offset + 46 + nameLength), allowMalformed: true)
        .replaceAll('\\', '/');
    if (name.startsWith('/') || RegExp(r'^[A-Za-z]:/').hasMatch(name) || name.split('/').contains('..')) {
      throw ReaderParseException('unsafe_zip_path', 'Unsafe ZIP entry path: $name');
    }
    if (!names.add(name)) {
      throw ReaderParseException('duplicate_zip_entry', 'Duplicate ZIP entry: $name');
    }
    if (compressed == 0xffffffff || uncompressed == 0xffffffff) {
      throw const ReaderParseException('zip64_not_supported', 'ZIP64 entries are not accepted by the reader parser.');
    }
    if (uncompressed > limits.maxZipEntryBytes) {
      throw ReaderParseException('zip_entry_too_large', '$name expands to $uncompressed bytes.');
    }
    if (uncompressed > 0 && compressed == 0) {
      throw ReaderParseException('invalid_compression_ratio', '$name has no bounded compressed size.');
    }
    if (compressed > 0 && uncompressed ~/ compressed > limits.maxCompressionRatio) {
      throw ReaderParseException('compression_ratio_exceeded', '$name exceeds compression ratio limit.');
    }
    expanded += uncompressed;
    entries += 1;
    if (entries > limits.maxZipEntries) {
      throw ReaderParseException('too_many_zip_entries', 'ZIP contains more than ${limits.maxZipEntries} entries.');
    }
    if (expanded > limits.maxZipExpandedBytes) {
      throw ReaderParseException('zip_expanded_too_large', 'ZIP expands beyond ${limits.maxZipExpandedBytes} bytes.');
    }
    offset = end;
  }
  if (offset != directoryEnd || entries != expectedEntries) {
    throw const ReaderParseException('invalid_zip_directory', 'ZIP central directory entry count is inconsistent.');
  }
  return _ZipInspection(Set.unmodifiable(names), expanded);
}

int _findZipEndOfCentralDirectory(Uint8List bytes) {
  const minimumRecordSize = 22;
  const maximumCommentSize = 0xffff;
  if (bytes.length < minimumRecordSize) return -1;
  final firstCandidate = math.max(0, bytes.length - minimumRecordSize - maximumCommentSize);
  for (var offset = bytes.length - minimumRecordSize; offset >= firstCandidate; offset -= 1) {
    if (_readLe32(bytes, offset) == 0x06054b50) return offset;
  }
  return -1;
}

int _readLe16(Uint8List bytes, int offset) => bytes[offset] | (bytes[offset + 1] << 8);

int _readLe32(Uint8List bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24);

class _RichDocumentParseOperation {
  final Completer<_Fb2Document> _completer = Completer<_Fb2Document>();
  Isolate? _isolate;
  ReceivePort? _port;
  bool _started = false;
  bool _cancelled = false;

  Future<_Fb2Document> parse(_RichSourceKind kind, File file) {
    _started = true;
    unawaited(_start(kind, file.path));
    return _completer.future;
  }

  Future<void> _start(_RichSourceKind kind, String path) async {
    final port = ReceivePort();
    _port = port;
    try {
      _isolate = await Isolate.spawn<List<Object?>>(_richDocumentParseWorker, [port.sendPort, kind.name, path]);
      if (_cancelled) {
        _isolate?.kill(priority: Isolate.immediate);
        return;
      }
      final response = await port.first;
      if (_cancelled || _completer.isCompleted) return;
      if (response is List && response.length == 2 && response.first == true) {
        _completer.complete(response[1]! as _Fb2Document);
      } else {
        _completer.completeError(
          ReaderParseException(
            'parse_failed',
            response is List && response.length > 1 ? '${response[1]}' : '$response',
          ),
        );
      }
    } catch (error, stackTrace) {
      if (!_cancelled && !_completer.isCompleted) _completer.completeError(error, stackTrace);
    } finally {
      port.close();
      _port = null;
      _isolate = null;
    }
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _isolate?.kill(priority: Isolate.immediate);
    _port?.close();
    if (_started && !_completer.isCompleted) _completer.completeError(const ReaderParseCancelledException());
  }
}

void _richDocumentParseWorker(List<Object?> request) {
  unawaited(_richDocumentParseWorkerAsync(request));
}

Future<void> _richDocumentParseWorkerAsync(List<Object?> request) async {
  final sendPort = request[0]! as SendPort;
  try {
    final kind = _RichSourceKind.values.byName(request[1]! as String);
    final document = await _parseReaderDocumentFromFile(kind: kind, file: File(request[2]! as String));
    sendPort.send([true, document]);
  } catch (error, stackTrace) {
    sendPort.send([false, '$error\n$stackTrace']);
  }
}
