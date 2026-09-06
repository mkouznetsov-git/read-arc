import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:archive/archive.dart';
import 'package:qr_code_scanner_plus/qr_code_scanner_plus.dart';
import 'package:pdfx/pdfx.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/book.dart';
import '../models/manifest.dart';
import '../models/sync_settings.dart';
import '../services/book_import_service.dart';
import '../services/format_engines/djvu_embedded_engine.dart';
import '../services/format_engines/djvu_embedded_probe.dart';
import '../services/storage_service.dart';
import '../services/sync/sync_service.dart';
import '../ui/app_theme.dart';

part '../reader/reader_regression_platform.dart';
part '../reader/formats/txt_reader_adapter.dart';
part '../reader/formats/fb2_reader_adapter.dart';
part '../reader/formats/epub_reader_adapter.dart';
part '../reader/formats/pdf_reader_adapter.dart';
part '../reader/formats/docx_reader_adapter.dart';
part '../reader/formats/djvu_reader_adapter.dart';

bool get _isDesktopReaderPlatform => Platform.isMacOS || Platform.isLinux || Platform.isWindows;
bool get _isAndroidReaderPlatform => Platform.isAndroid;

const Color _raIndigoCard = Color(0xFF302849);
const Color _raWarmGold = Color(0xFFC9AA78);
const Color _raPaper = Color(0xFFF3E7CF);
const Color _raInkBlue = Color(0xFF2A2F4A);
const Color _raMutedPaper = Color(0xFFCFC5B5);
const Color _raFaintIndigo = Color(0xFF4A405F);

void runReadArcApp() {
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        debugPrint('ReadArc Flutter error: ${details.exceptionAsString()}\n${details.stack}');
      };
      PlatformDispatcher.instance.onError = (error, stack) {
        debugPrint('ReadArc uncaught platform error: $error\n$stack');
        return true;
      };
      runApp(const ReadArcApp());
    },
    (error, stack) {
      debugPrint('ReadArc uncaught zone error: $error\n$stack');
    },
  );
}

class ReadArcApp extends StatefulWidget {
  const ReadArcApp({super.key, this.autoConnect = true, this.storage, this.sync, this.disposeSync = true})
    : assert(sync == null || storage != null);

  final bool autoConnect;
  final StorageService? storage;
  final SyncService? sync;
  final bool disposeSync;

  @override
  State<ReadArcApp> createState() => _ReadArcAppState();
}

class _ReadArcAppState extends State<ReadArcApp> {
  late final _storage = widget.storage ?? StorageService();
  late final _sync = widget.sync ?? SyncService(_storage);

  @override
  void initState() {
    super.initState();
    if (widget.autoConnect) unawaited(_autoConnectSync());
  }

  Future<void> _autoConnectSync() async {
    try {
      final settings = await _storage.loadSyncSettings();
      if (!settings.autoConnect) return;
      if (settings.usesOfficialPlaceholder) return;
      await _sync.connect(relayUrl: settings.effectiveRelayUrl);
    } catch (error) {
      debugPrint('ReadArc auto-connect failed: $error');
      final settings = await _storage.loadSyncSettings();
      if (settings.autoConnect && !settings.usesOfficialPlaceholder) {
        _sync.startAutoReconnect(relayUrl: settings.effectiveRelayUrl);
      }
    }
  }

  @override
  void dispose() {
    if (widget.disposeSync) unawaited(_sync.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ReadArc',
      theme: ReadArcTheme.light(),
      home: LibraryScreen(storage: _storage, sync: _sync),
    );
  }
}

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.storage, required this.sync});

  final StorageService storage;
  final SyncService sync;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  late final _importService = BookImportService(widget.storage);
  LibraryManifest? _manifest;
  bool _busy = false;
  bool _bulkDownloadBusy = false;
  String? _libraryLoadError;
  StreamSubscription<LibraryManifest>? _syncSubscription;

  @override
  void initState() {
    super.initState();
    _syncSubscription = widget.sync.manifestChanges.listen((_) => _reload());
    _reload();
  }

  @override
  void dispose() {
    unawaited(_syncSubscription?.cancel());
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      final manifest = await widget.storage.loadManifest().timeout(const Duration(seconds: 12));
      if (mounted) {
        setState(() {
          _manifest = manifest;
          _libraryLoadError = null;
        });
      }
    } catch (error, stackTrace) {
      debugPrint('ReadArc manifest load failed: $error\n$stackTrace');
      if (!mounted) return;
      setState(() => _libraryLoadError = 'Не удалось загрузить библиотеку: $error');
    }
  }

  Future<void> _addBook() async {
    setState(() => _busy = true);
    try {
      final book = await _importService.pickAndImport();
      if (book != null) {
        await widget.sync.broadcastLibrarySnapshot(reason: 'book_imported');
      }
      await _reload();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось добавить книгу: $error')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _downloadBook(BookRecord book) async {
    if (!widget.sync.state.value.connected) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Нет подключения к relay.')));
      return;
    }

    final started = await widget.sync.requestBookFile(book);
    if (!mounted) return;
    if (!started) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Не удалось начать скачивание. Проверьте подключение к relay.')));
    }
  }

  Future<void> _downloadWholeLibrary(List<BookRecord> books) async {
    final toDownload = books.where((book) => !book.isDownloaded && !book.isDeleted).toList();
    if (toDownload.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Все книги уже скачаны на это устройство.')));
      return;
    }
    if (!widget.sync.state.value.connected) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Нет подключения к relay.')));
      return;
    }
    final totalBytes = toDownload.fold<int>(0, (sum, book) => sum + book.sizeBytes);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Скачать всю библиотеку?'),
        content: Text(
          'Скачать всю библиотеку (${_formatUiBytes(totalBytes)}) на это устройство?\n\n'
          'Будет загружено книг: ${toDownload.length}.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Нет')),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.download_for_offline_outlined),
            label: const Text('Да, скачать'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _bulkDownloadBusy = true);
    var started = 0;
    var completed = 0;
    try {
      for (final book in toDownload) {
        if (!mounted) break;
        final currentManifest = await widget.storage.loadManifest();
        BookRecord? currentBook;
        for (final candidate in currentManifest.books) {
          if (candidate.id == book.id) {
            currentBook = candidate;
            break;
          }
        }
        if (currentBook?.isDownloaded == true) {
          completed += 1;
          continue;
        }
        final ok = await widget.sync.requestBookFile(currentBook ?? book);
        if (ok) {
          started += 1;
          final done = await _waitForBookDownloaded(book.id, timeout: const Duration(minutes: 10));
          if (done) completed += 1;
        }
        await _reload();
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Скачивание библиотеки: завершено $completed, запущено $started.')));
    } finally {
      if (mounted) setState(() => _bulkDownloadBusy = false);
    }
  }

  Future<bool> _waitForBookDownloaded(String bookId, {required Duration timeout}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final manifest = await widget.storage.loadManifest();
      for (final book in manifest.books) {
        if (book.id == bookId) {
          if (book.isDownloaded) return true;
          final transfer = widget.sync.state.value.downloadForBook(bookId);
          if (transfer != null && transfer.hasError && transfer.active == false) return false;
          break;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
    return false;
  }

  Future<void> _cancelBookDownload(BookRecord book) async {
    await widget.sync.cancelBookFileDownload(book.id);
  }

  Future<void> _removeLocalCopy(BookRecord book) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить с устройства?'),
        content: Text(
          'Книга «${book.title}» останется в библиотеке аккаунта, но файл будет удалён с этого устройства. Позже её можно будет скачать снова с другого устройства.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Удалить файл')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.storage.removeLocalBookCopy(book.id);
      await widget.sync.broadcastLibrarySnapshot(reason: 'local_copy_removed');
      await _reload();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось удалить файл: $error')));
    }
  }

  Future<void> _deleteFromLibrary(BookRecord book) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить книгу из библиотеки?'),
        content: Text(
          'Книга «${book.title}» исчезнет из библиотеки аккаунта на всех устройствах после синхронизации. Локальный файл на этом устройстве будет удалён.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Удалить из библиотеки')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.storage.deleteBookFromLibrary(book.id);
      await widget.sync.broadcastLibrarySnapshot(reason: 'book_deleted');
      await _reload();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось удалить книгу: $error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final manifest = _manifest;
    final books = manifest?.visibleBooks ?? [];

    return Scaffold(
      appBar: AppBar(
        leading: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.asset('assets/brand/readarc_icon_128.png'),
          ),
        ),
        title: const Text('ReadArc'),
        actions: [
          ValueListenableBuilder<SyncStateSnapshot>(
            valueListenable: widget.sync.state,
            builder: (context, syncState, _) {
              final hasRemoteBooks = books.any((book) => !book.isDownloaded && !book.isDeleted);
              return IconButton(
                tooltip: syncState.connected
                    ? 'Скачать всю библиотеку на устройство'
                    : 'Скачивание недоступно: relay не подключен',
                onPressed: (!syncState.connected || _bulkDownloadBusy || !hasRemoteBooks)
                    ? null
                    : () => _downloadWholeLibrary(books),
                icon: _bulkDownloadBusy
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.download_for_offline_outlined),
              );
            },
          ),
          ValueListenableBuilder<SyncStateSnapshot>(
            valueListenable: widget.sync.state,
            builder: (context, syncState, _) {
              return IconButton(
                tooltip: syncState.connected ? 'Синхронизация подключена' : 'Синхронизация',
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SyncScreen(storage: widget.storage, sync: widget.sync),
                    ),
                  );
                  await _reload();
                },
                icon: Icon(syncState.connected ? Icons.sync_rounded : Icons.sync_disabled_rounded),
              );
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _addBook,
        icon: _busy
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.add_rounded),
        label: const Text('Добавить книгу'),
      ),
      body: _libraryLoadError != null && manifest == null
          ? _LibraryLoadErrorView(message: _libraryLoadError!, onRetry: _reload)
          : manifest == null
          ? const Center(child: CircularProgressIndicator())
          : books.isEmpty
          ? const _EmptyLibrary()
          : ValueListenableBuilder<SyncStateSnapshot>(
              valueListenable: widget.sync.state,
              builder: (context, syncState, _) {
                return ListView.builder(
                  padding: const EdgeInsets.only(bottom: 96),
                  itemCount: books.length,
                  itemBuilder: (context, index) {
                    final book = books[index];
                    final transfer = syncState.downloadForBook(book.id);
                    return _BookCard(
                      book: book,
                      transfer: transfer,
                      onDownload: syncState.connected && !book.isDownloaded && transfer?.active != true
                          ? () => _downloadBook(book)
                          : null,
                      onCancelDownload: transfer?.active == true ? () => _cancelBookDownload(book) : null,
                      onRemoveLocalCopy: book.isDownloaded ? () => _removeLocalCopy(book) : null,
                      onDeleteFromLibrary: () => _deleteFromLibrary(book),
                      onOpen: book.isDownloaded
                          ? () async {
                              await Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => ReaderScreen(book: book, storage: widget.storage, sync: widget.sync),
                                ),
                              );
                              await _reload();
                            }
                          : null,
                    );
                  },
                );
              },
            ),
    );
  }
}

String _formatUiBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

class _LibraryLoadErrorView extends StatelessWidget {
  const _LibraryLoadErrorView({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, size: 42, color: _raWarmGold),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _raMutedPaper),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: () => unawaited(onRetry()),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Повторить'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Text(
          'Библиотека пока пуста. Добавьте книгу — она будет скопирована в локальное хранилище устройства.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _BookCard extends StatelessWidget {
  const _BookCard({
    required this.book,
    required this.onOpen,
    required this.onDownload,
    required this.onCancelDownload,
    required this.onRemoveLocalCopy,
    required this.onDeleteFromLibrary,
    required this.transfer,
  });

  final BookRecord book;
  final VoidCallback? onOpen;
  final VoidCallback? onDownload;
  final VoidCallback? onCancelDownload;
  final VoidCallback? onRemoveLocalCopy;
  final VoidCallback onDeleteFromLibrary;
  final FileTransferSnapshot? transfer;

  @override
  Widget build(BuildContext context) {
    final progressValue = (book.progressPercent.clamp(0, 100) / 100).toDouble();
    final transfer = this.transfer;
    final isDownloading = transfer?.active == true;
    final hasDownloadError = transfer?.hasError == true;
    final showTransfer = transfer != null && !book.isDownloaded && (isDownloading || hasDownloadError);
    final format = book.format.toUpperCase();
    final sizeText = _formatUiBytes(book.sizeBytes);
    final progressText = '${book.progressPercent.clamp(0, 100).toStringAsFixed(0)}%';

    return Card(
      color: _raIndigoCard,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: _raWarmGold.withValues(alpha: 0.18)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: book.isDownloaded ? onOpen : onDownload,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                book.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(color: _raPaper, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 9),
              Row(
                children: [
                  _LibraryMetaChip(label: format),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6),
                    child: Text('•', style: TextStyle(color: _raMutedPaper, fontSize: 11)),
                  ),
                  _LibraryMetaChip(label: sizeText),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Tooltip(
                      message: 'Прочитано $progressText',
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: progressValue,
                          minHeight: 4,
                          valueColor: const AlwaysStoppedAnimation<Color>(_raWarmGold),
                          backgroundColor: _raFaintIndigo.withValues(alpha: 0.95),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 7),
                  SizedBox(
                    width: 42,
                    child: Text(
                      progressText,
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      style: const TextStyle(color: _raMutedPaper, fontSize: 11, fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (isDownloading)
                    IconButton(
                      tooltip: 'Отменить скачивание',
                      visualDensity: VisualDensity.compact,
                      color: _raWarmGold,
                      onPressed: onCancelDownload,
                      icon: const Icon(Icons.cancel_outlined),
                    )
                  else
                    TextButton.icon(
                      onPressed: book.isDownloaded ? onOpen : onDownload,
                      icon: Icon(book.isDownloaded ? Icons.menu_book_rounded : Icons.cloud_download_outlined, size: 17),
                      label: Text(book.isDownloaded ? 'Читать' : 'Скачать'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor: _raWarmGold,
                        backgroundColor: _raWarmGold.withValues(alpha: 0.12),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                      ),
                    ),
                  PopupMenuButton<_BookAction>(
                    tooltip: 'Действия с книгой',
                    iconColor: _raWarmGold,
                    onSelected: (action) {
                      switch (action) {
                        case _BookAction.removeLocalCopy:
                          onRemoveLocalCopy?.call();
                          break;
                        case _BookAction.deleteFromLibrary:
                          onDeleteFromLibrary();
                          break;
                      }
                    },
                    itemBuilder: (context) => [
                      if (book.isDownloaded)
                        const PopupMenuItem(value: _BookAction.removeLocalCopy, child: Text('Удалить с устройства')),
                      const PopupMenuItem(value: _BookAction.deleteFromLibrary, child: Text('Удалить из библиотеки')),
                    ],
                  ),
                ],
              ),
              if (showTransfer) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(value: transfer.progressPercent.clamp(0, 100) / 100, minHeight: 4),
                ),
                const SizedBox(height: 4),
                Text(
                  hasDownloadError ? (transfer.error ?? 'Ошибка скачивания') : transfer.statusText,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _LibraryMetaChip extends StatelessWidget {
  const _LibraryMetaChip({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.2, color: _raMutedPaper),
    );
  }
}

enum _BookAction { removeLocalCopy, deleteFromLibrary }

class ReaderScreen extends StatelessWidget {
  const ReaderScreen({super.key, required this.book, required this.storage, required this.sync});

  final BookRecord book;
  final StorageService storage;
  final SyncService sync;

  @override
  Widget build(BuildContext context) {
    switch (book.format.toLowerCase()) {
      case 'txt':
        return _TxtReaderScreen(book: book, storage: storage, sync: sync);
      case 'fb2':
        return _Fb2ReaderScreen(book: book, storage: storage, sync: sync);
      case 'epub':
        return _Fb2ReaderScreen(book: book, storage: storage, sync: sync, sourceKind: _RichSourceKind.epub);
      case 'docx':
        return _DocxReaderScreen(book: book, storage: storage, sync: sync);
      case 'doc':
        return _Fb2ReaderScreen(book: book, storage: storage, sync: sync, sourceKind: _RichSourceKind.doc);
      case 'chm':
        return _ChmSafeReaderScreen(book: book, storage: storage, sync: sync);
      case 'djvu':
      case 'djv':
        return _DjvuReaderScreen(book: book, storage: storage, sync: sync);
      case 'pdf':
        return _PdfReaderScreen(book: book, storage: storage, sync: sync);
      default:
        return Scaffold(
          appBar: AppBar(title: Text(book.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
          body: _UnsupportedReaderPlaceholder(book: book),
        );
    }
  }
}

class _TxtReaderScreen extends StatefulWidget {
  const _TxtReaderScreen({required this.book, required this.storage, required this.sync});

  final BookRecord book;
  final StorageService storage;
  final SyncService sync;

  @override
  State<_TxtReaderScreen> createState() => _TxtReaderScreenState();
}

class _TxtReaderScreenState extends State<_TxtReaderScreen> {
  // TXT reader v4: one native Flutter ListView with fixed-height text rows.
  // This is deliberately boring: fixed item extent gives macOS a stable scroll
  // extent, Android gets a normal scrollbar, and the saved locator is the first
  // source character of the line touching the top of the viewport.
  static const _fontSize = 18.0;
  static const _heightFactor = 1.65;
  static const _readerTextStyle = TextStyle(fontSize: _fontSize, height: _heightFactor, color: Color(0xFF2A2F4A));
  static const _lineExtent = _fontSize * _heightFactor;
  static const _horizontalReaderPadding = 24.0;
  static const _topPadding = 18.0;
  static const _bottomPadding = 28.0;

  final _scrollController = ScrollController();
  String? _rawText;
  List<_TextLine>? _lines;
  int _totalChars = 0;
  int _pendingAnchorChar = 0;
  double _lastUsableWidth = 0;
  bool _restoringPosition = false;
  bool _didInitialRestore = false;
  String? _loadError;
  Timer? _saveDebounce;
  Timer? _resizeDebounce;
  Timer? _progressRedrawThrottle;
  double _lastProgress = 0;
  BookRecord? _runtimeBook;
  _TextAnchorLocator? _lastKnownLocator;
  bool _fullScreen = false;
  bool _textProgressScrubActive = false;

  BookRecord get _book => _runtimeBook ?? widget.book;

  Future<BookRecord> _loadCurrentBook() async {
    final manifest = await widget.storage.loadManifest();
    for (final book in manifest.books) {
      if (book.id == widget.book.id) return book;
    }
    return widget.book;
  }

  @override
  void initState() {
    super.initState();
    _lastProgress = widget.book.progressPercent;
    _scrollController.addListener(_onScrollPositionChanged);
    _load();
  }

  @override
  void dispose() {
    _resizeDebounce?.cancel();
    _saveDebounce?.cancel();
    _progressRedrawThrottle?.cancel();
    final locator = _currentLocator() ?? _lastKnownLocator;
    if (locator != null) {
      unawaited(_saveProgress(locator));
    }
    _scrollController.removeListener(_onScrollPositionChanged);
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final book = await _loadCurrentBook();
    if (!mounted) return;
    _runtimeBook = book;
    if (book.localPath == null) {
      setState(() => _loadError = 'Файл книги не скачан на это устройство');
      return;
    }

    try {
      final file = File(book.localPath!);
      if (!await file.exists()) throw StateError('Файл отсутствует: ${book.localPath}');
      final bytes = await file.readAsBytes();
      final raw = _normalizeText(await compute(_decodeTextFile, bytes));
      final totalChars = raw.length;
      final targetChar = _targetCharForBook(book, totalChars);
      if (!mounted) return;
      setState(() {
        _rawText = raw;
        _totalChars = totalChars;
        _pendingAnchorChar = targetChar;
        _lastKnownLocator = targetChar >= totalChars && totalChars > 0
            ? _locatorForEnd()
            : _locatorForAnchorChar(targetChar);
        _lastProgress = _lastKnownLocator?.progressPercent ?? 0;
        _loadError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadError = 'Не удалось открыть TXT: $error');
    }
  }

  void _ensureLinesForWidth(double maxWidth) {
    final raw = _rawText;
    if (raw == null) return;
    final usableWidth = (maxWidth - (_horizontalReaderPadding * 2)).clamp(180.0, 2000.0).toDouble();
    if (_lines != null && (usableWidth - _lastUsableWidth).abs() < 8) return;

    // Keep the current top source position across window resizes. Debouncing
    // avoids doing text wrapping dozens of times while the user drags the edge.
    final anchor = _currentLocator()?.anchorChar ?? _pendingAnchorChar;
    _resizeDebounce?.cancel();
    _resizeDebounce = Timer(const Duration(milliseconds: 90), () {
      if (!mounted) return;
      final built = _buildDisplayLines(raw, usableWidth);
      setState(() {
        _lines = built.isEmpty ? [const _TextLine(text: '', startChar: 0, endChar: 0)] : built;
        _lastUsableWidth = usableWidth;
        _pendingAnchorChar = anchor.clamp(0, _totalChars).toInt();
      });
      _scheduleRestoreScroll();
    });
  }

  void _scheduleRestoreScroll() {
    if (_rawText == null || _lines == null) return;
    _restoringPosition = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        for (var attempt = 0; attempt < 16; attempt++) {
          await Future<void>.delayed(Duration(milliseconds: attempt == 0 ? 16 : 35));
          if (!mounted || !_scrollController.hasClients) continue;
          final target = _offsetForAnchorChar(_pendingAnchorChar);
          _scrollController.jumpTo(target.clamp(0.0, _scrollController.position.maxScrollExtent));
          final locator = _currentLocator() ?? _lastKnownLocator;
          _lastKnownLocator = locator;
          _lastProgress = locator?.progressPercent ?? _lastProgress;
          _didInitialRestore = true;
          if (mounted) setState(() {});
          break;
        }
      } finally {
        _restoringPosition = false;
      }
    });
  }

  int _targetCharForBook(BookRecord book, int totalChars) {
    if (totalChars <= 0) return 0;
    final decoded = _tryDecodeLocatorJson(book.currentLocator);
    if (decoded != null) {
      final type = decoded['type'];
      if (type == 'txt-line-anchor-v1' ||
          type == 'fb2-line-anchor-v1' ||
          type == 'epub-line-anchor-v1' ||
          type == 'docx-line-anchor-v1' ||
          type == 'doc-line-anchor-v1' ||
          type == 'chm-line-anchor-v1' ||
          type == 'djvu-line-anchor-v1' ||
          type == 'txt-top-anchor-v3' ||
          type == 'txt-top-anchor-v2' ||
          type == 'txt-top-anchor-v1' ||
          type == 'txt-anchor-v1') {
        return ((decoded['anchorChar'] as num?)?.round() ?? 0).clamp(0, totalChars).toInt();
      }
      if (type == 'txt-page-v3' || type == 'txt-page-v2') {
        return ((decoded['anchorChar'] as num?)?.round() ?? (decoded['startChar'] as num?)?.round() ?? 0)
            .clamp(0, totalChars)
            .toInt();
      }
      if (type == 'txt-page-v1') {
        final startChar = (decoded['startChar'] as num?)?.round();
        if (startChar != null) return startChar.clamp(0, totalChars).toInt();
        final pageIndex = ((decoded['pageIndex'] as num?)?.round() ?? 0).clamp(0, 1000000).toInt();
        final pageCount = ((decoded['pageCount'] as num?)?.round() ?? 0).clamp(0, 1000000).toInt();
        if (pageCount > 0) return ((pageIndex / pageCount) * totalChars).round().clamp(0, totalChars).toInt();
      }
      if (type == 'txt-char-v1') {
        return ((decoded['charIndex'] as num?)?.round() ?? 0).clamp(0, totalChars).toInt();
      }
    }
    final progress = book.progressPercent.clamp(0.0, 100.0).toDouble();
    return ((progress / 100.0) * totalChars).round().clamp(0, totalChars).toInt();
  }

  Map<String, dynamic>? _tryDecodeLocatorJson(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) return decoded.map((key, value) => MapEntry(key.toString(), value));
    } catch (_) {}
    return null;
  }

  _TextAnchorLocator? _currentLocator() {
    if (_totalChars <= 0) return null;
    if (!_scrollController.hasClients) return _lastKnownLocator ?? _locatorForAnchorChar(_pendingAnchorChar);
    if (_isAtBottom()) return _locatorForEnd();
    final lines = _lines;
    if (lines == null || lines.isEmpty) return _lastKnownLocator;
    final lineIndex = _topLineIndexFromOffset(_scrollController.offset);
    final safeIndex = lineIndex.clamp(0, lines.length - 1).toInt();
    final line = lines[safeIndex];
    return _TextAnchorLocator(
      anchorChar: line.startChar.clamp(0, _totalChars).toInt(),
      totalChars: _totalChars,
      lineIndex: safeIndex,
      lineCount: lines.length,
      scrollOffset: _scrollController.offset,
      maxScrollExtent: _scrollController.position.maxScrollExtent,
      viewportWidth: _lastUsableWidth,
    );
  }

  bool _isAtBottom() {
    if (!_scrollController.hasClients) return false;
    final position = _scrollController.position;
    return position.maxScrollExtent <= 0 || position.extentAfter <= 8;
  }

  _TextAnchorLocator _locatorForEnd() {
    final lines = _lines ?? const <_TextLine>[];
    return _TextAnchorLocator(
      anchorChar: _totalChars,
      totalChars: _totalChars,
      lineIndex: lines.isEmpty ? 0 : lines.length - 1,
      lineCount: lines.length,
      scrollOffset: _scrollController.hasClients ? _scrollController.offset : null,
      maxScrollExtent: _scrollController.hasClients ? _scrollController.position.maxScrollExtent : null,
      viewportWidth: _lastUsableWidth,
    );
  }

  _TextAnchorLocator _locatorForAnchorChar(int anchorChar) {
    final lines = _lines ?? const <_TextLine>[];
    final index = _lineIndexForChar(lines, anchorChar.clamp(0, _totalChars).toInt());
    return _TextAnchorLocator(
      anchorChar: anchorChar.clamp(0, _totalChars).toInt(),
      totalChars: _totalChars,
      lineIndex: index,
      lineCount: lines.length,
      viewportWidth: _lastUsableWidth,
    );
  }

  int _topLineIndexFromOffset(double offset) {
    final contentOffset = (offset - _topPadding).clamp(0.0, double.infinity).toDouble();
    return (contentOffset / _lineExtent).floor();
  }

  double _offsetForAnchorChar(int anchorChar) {
    final lines = _lines ?? const <_TextLine>[];
    if (lines.isEmpty) return 0;
    if (anchorChar >= _totalChars && _totalChars > 0 && _scrollController.hasClients) {
      return _scrollController.position.maxScrollExtent;
    }
    final index = _lineIndexForChar(lines, anchorChar.clamp(0, _totalChars).toInt());
    return _topPadding + index * _lineExtent;
  }

  void _onScrollPositionChanged() {
    if (_restoringPosition || !_didInitialRestore) return;
    final locator = _currentLocator();
    if (locator == null) return;
    _lastKnownLocator = locator;
    _lastProgress = locator.progressPercent;
    _scheduleProgressRedraw();
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 1100), () {
      unawaited(_saveProgress(locator));
    });
  }

  void _scheduleProgressRedraw() {
    if (_progressRedrawThrottle?.isActive ?? false) return;
    _progressRedrawThrottle = Timer(const Duration(milliseconds: 140), () {
      if (mounted) setState(() {});
    });
  }

  void _setTextProgressFromFraction(double fraction) {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final target = (position.maxScrollExtent * fraction.clamp(0.0, 1.0))
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    _scrollController.jumpTo(target);
    final locator = _currentLocator();
    if (locator != null) {
      _lastKnownLocator = locator;
      _lastProgress = locator.progressPercent;
      _saveDebounce?.cancel();
      _saveDebounce = Timer(const Duration(milliseconds: 450), () => unawaited(_saveProgress(locator)));
    }
    if (mounted) setState(() {});
  }

  void _deactivateTextProgressScrub() {
    if (_textProgressScrubActive) setState(() => _textProgressScrubActive = false);
  }

  String get _textLocatorType => 'txt-line-anchor-v1';

  String get _textReaderLabel => 'TXT';

  Future<void> _copyVisibleText() async {
    final lines = _lines;
    if (lines == null || lines.isEmpty) return;
    final current = _currentLocator();
    final start = (current?.lineIndex ?? 0).clamp(0, lines.length - 1).toInt();
    final end = (start + 36).clamp(start + 1, lines.length).toInt();
    final text = lines.sublist(start, end).map((line) => line.text).join('\n').trimRight();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Скопирован фрагмент $_textReaderLabel (${end - start} строк)')));
  }

  Future<void> _saveProgress(_TextAnchorLocator locator) async {
    final manifest = await widget.storage.updateProgress(
      bookId: widget.book.id,
      progressPercent: locator.progressPercent,
      locator: locator.toJsonString(type: _textLocatorType),
    );
    for (final book in manifest.books) {
      if (book.id == widget.book.id) {
        _runtimeBook = book;
        break;
      }
    }
    await widget.sync.broadcastLibrarySnapshot(reason: 'progress_updated');
  }

  Future<void> _addBookmark() async {
    final locator = _currentLocator();
    await widget.storage.addBookmark(
      bookId: widget.book.id,
      label: 'Закладка ${DateTime.now().toLocal().toIso8601String().substring(0, 16)}',
      locator: locator?.toJsonString(type: _textLocatorType) ?? _book.currentLocator,
    );
    await widget.sync.broadcastLibrarySnapshot(reason: 'bookmark_added');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Закладка добавлена')));
  }

  @override
  Widget build(BuildContext context) {
    final raw = _rawText;
    final lines = _lines;
    return Scaffold(
      backgroundColor: const Color(0xFFF3E7CF),
      appBar: _fullScreen
          ? null
          : AppBar(
              title: Text(_book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              actions: [
                IconButton(
                  tooltip: 'Полный экран',
                  onPressed: () => setState(() => _fullScreen = true),
                  icon: const Icon(Icons.fullscreen_rounded),
                ),
                IconButton(
                  tooltip: 'Скопировать видимый фрагмент',
                  onPressed: lines != null ? _copyVisibleText : null,
                  icon: const Icon(Icons.copy_all_rounded),
                ),
                IconButton(
                  tooltip: 'Добавить закладку',
                  onPressed: lines != null ? _addBookmark : null,
                  icon: const Icon(Icons.bookmark_add_outlined),
                ),
              ],
            ),
      floatingActionButton: _fullScreen
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton.small(
                  heroTag: 'txt-copy-${widget.book.id}',
                  tooltip: 'Скопировать видимый фрагмент',
                  onPressed: lines != null ? _copyVisibleText : null,
                  child: const Icon(Icons.copy_all_rounded),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'txt-bookmark-${widget.book.id}',
                  tooltip: 'Добавить закладку',
                  onPressed: lines != null ? _addBookmark : null,
                  child: const Icon(Icons.bookmark_add_outlined),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'txt-exit-fullscreen-${widget.book.id}',
                  tooltip: 'Выйти из полного экрана',
                  onPressed: () => setState(() => _fullScreen = false),
                  child: const Icon(Icons.fullscreen_exit_rounded),
                ),
              ],
            )
          : null,
      body: _loadError != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Text(_loadError!, textAlign: TextAlign.center),
              ),
            )
          : raw == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      _ensureLinesForWidth(constraints.maxWidth);
                      final currentLines = _lines;
                      if (currentLines == null) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      return GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: _deactivateTextProgressScrub,
                        child: SelectionArea(
                          child: Scrollbar(
                            controller: _scrollController,
                            thumbVisibility: true,
                            interactive: true,
                            child: ListView.builder(
                              scrollCacheExtent: const ScrollCacheExtent.pixels(_lineExtent * 60),
                              controller: _scrollController,
                              padding: const EdgeInsets.fromLTRB(
                                _horizontalReaderPadding,
                                _topPadding,
                                _horizontalReaderPadding,
                                _bottomPadding,
                              ),
                              itemExtent: _lineExtent,
                              itemCount: currentLines.length,
                              itemBuilder: (context, index) {
                                final line = currentLines[index];
                                return Text(
                                  line.text,
                                  maxLines: 1,
                                  overflow: TextOverflow.clip,
                                  softWrap: false,
                                  style: _readerTextStyle,
                                );
                              },
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                if (!_fullScreen)
                  _ContinuousReaderProgressBar(
                    progress: (_lastProgress.clamp(0, 100) / 100).toDouble(),
                    label: '${_lastProgress.clamp(0, 100).toStringAsFixed(1)}%',
                    active: _textProgressScrubActive,
                    onActivate: () => setState(() => _textProgressScrubActive = true),
                    onFractionSelected: _setTextProgressFromFraction,
                  ),
              ],
            ),
    );
  }
}

class _DocxReaderScreen extends StatefulWidget {
  const _DocxReaderScreen({required this.book, required this.storage, required this.sync});

  final BookRecord book;
  final StorageService storage;
  final SyncService sync;

  @override
  State<_DocxReaderScreen> createState() => _DocxReaderScreenState();
}

class _DocxReaderScreenState extends State<_DocxReaderScreen> {
  final _scrollController = ScrollController();
  final _parseOperation = _RichDocumentParseOperation();
  BookRecord? _runtimeBook;
  _Fb2Document? _document;
  String? _loadError;
  bool _fullScreen = false;
  bool _docxProgressScrubActive = false;
  bool _restoring = false;
  Timer? _saveDebounce;
  Timer? _redrawThrottle;
  double _progress = 0;

  BookRecord get _book => _runtimeBook ?? widget.book;

  @override
  void initState() {
    super.initState();
    _progress = widget.book.progressPercent;
    _scrollController.addListener(_onScroll);
    unawaited(_load());
  }

  @override
  void dispose() {
    _parseOperation.cancel();
    _saveDebounce?.cancel();
    _redrawThrottle?.cancel();
    if (_document != null) {
      final progress = _currentProgress();
      unawaited(_saveProgress(progress));
    }
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final manifest = await widget.storage.loadManifest();
    var book = widget.book;
    for (final candidate in manifest.books) {
      if (candidate.id == widget.book.id) {
        book = candidate;
        break;
      }
    }
    const label = 'DOCX';
    if (book.localPath == null) {
      if (mounted) setState(() => _loadError = 'Файл $label не скачан на это устройство');
      return;
    }
    final file = File(book.localPath!);
    if (!await file.exists()) {
      if (mounted) setState(() => _loadError = 'Файл $label отсутствует: ${book.localPath}');
      return;
    }
    try {
      final document = await _parseReaderDocumentFromFileSafely(
        kind: _RichSourceKind.docx,
        file: file,
        operation: _parseOperation,
      );
      if (!mounted) return;
      setState(() {
        _runtimeBook = book;
        _document = document;
        _progress = book.progressPercent.clamp(0.0, 100.0).toDouble();
        _loadError = null;
      });
      _restoreScroll(_targetProgressForBook(book));
    } catch (error) {
      if (mounted) setState(() => _loadError = 'Не удалось открыть $label: $error');
    }
  }

  double _targetProgressForBook(BookRecord book) {
    try {
      final decoded = jsonDecode(book.currentLocator);
      if (decoded is Map && (decoded['type'] == _officeLocatorType || decoded['type'] == 'docx-rich-scroll-v1')) {
        return ((decoded['progressPercent'] as num?)?.toDouble() ?? book.progressPercent).clamp(0.0, 100.0).toDouble();
      }
    } catch (_) {}
    return book.progressPercent.clamp(0.0, 100.0).toDouble();
  }

  void _restoreScroll(double progress) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !_scrollController.hasClients) return;
      _restoring = true;
      try {
        for (var attempt = 0; attempt < 20; attempt++) {
          await Future<void>.delayed(Duration(milliseconds: attempt == 0 ? 24 : 40));
          if (!mounted || !_scrollController.hasClients) continue;
          final max = _scrollController.position.maxScrollExtent;
          if (max <= 0 && attempt < 8) continue;
          _scrollController.jumpTo((max * (progress / 100.0)).clamp(0.0, max));
          break;
        }
      } finally {
        _restoring = false;
      }
    });
  }

  double _currentProgress() {
    if (!_scrollController.hasClients) return _progress;
    final position = _scrollController.position;
    if (position.maxScrollExtent <= 0) return 0;
    return ((position.pixels / position.maxScrollExtent) * 100).clamp(0.0, 100.0).toDouble();
  }

  void _setDocxProgressFromFraction(double fraction) {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final target = (position.maxScrollExtent * fraction.clamp(0.0, 1.0))
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    _scrollController.jumpTo(target);
    final progress = _currentProgress();
    _progress = progress;
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 450), () => unawaited(_saveProgress(progress)));
    if (mounted) setState(() {});
  }

  void _deactivateDocxProgressScrub() {
    if (_docxProgressScrubActive) setState(() => _docxProgressScrubActive = false);
  }

  void _onScroll() {
    if (_restoring || !_scrollController.hasClients) return;
    final progress = _currentProgress();
    _progress = progress;
    if (!(_redrawThrottle?.isActive ?? false)) {
      _redrawThrottle = Timer(const Duration(milliseconds: 90), () {
        if (mounted) setState(() {});
      });
    }
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 600), () {
      unawaited(_saveProgress(progress));
    });
  }

  String get _officeLocatorType => 'docx-rich-scroll-v1';

  String _locatorJson(double progress) => jsonEncode({
    'type': _officeLocatorType,
    'progressPercent': progress.clamp(0.0, 100.0),
    'updatedAt': DateTime.now().toUtc().toIso8601String(),
  });

  Future<void> _saveProgress(double progress) async {
    await widget.storage.updateProgress(
      bookId: widget.book.id,
      progressPercent: progress.clamp(0.0, 100.0).toDouble(),
      locator: _locatorJson(progress),
    );
    await widget.sync.broadcastLibrarySnapshot(reason: 'docx_progress_updated');
  }

  Future<void> _copyAll() async {
    final doc = _document;
    if (doc == null) return;
    final text = [...doc.officeHeaderBlocks, ...doc.blocks, ...doc.officeFooterBlocks]
        .map((block) => block.plainText)
        .where((line) => line.trim().isNotEmpty && line != _officePageBreakMarker)
        .join('\n\n');
    if (text.trim().isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Текст DOCX скопирован')));
  }

  Future<void> _addBookmark() async {
    final progress = _currentProgress();
    await widget.storage.addBookmark(
      bookId: widget.book.id,
      label: 'Закладка DOCX ${DateTime.now().toLocal().toIso8601String().substring(0, 16)}',
      locator: _locatorJson(progress),
    );
    await widget.sync.broadcastLibrarySnapshot(reason: 'bookmark_added');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Закладка добавлена')));
  }

  @override
  Widget build(BuildContext context) {
    final document = _document;
    return Scaffold(
      backgroundColor: const Color(0xFFF3E7CF),
      appBar: _fullScreen
          ? null
          : AppBar(
              title: Text(_book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              actions: [
                IconButton(
                  tooltip: 'Скопировать текст документа',
                  onPressed: document == null ? null : _copyAll,
                  icon: const Icon(Icons.copy_all_rounded),
                ),
                IconButton(
                  tooltip: 'Полный экран',
                  onPressed: () => setState(() => _fullScreen = true),
                  icon: const Icon(Icons.fullscreen_rounded),
                ),
                IconButton(
                  tooltip: 'Добавить закладку',
                  onPressed: document == null ? null : _addBookmark,
                  icon: const Icon(Icons.bookmark_add_outlined),
                ),
              ],
            ),
      floatingActionButton: _fullScreen
          ? FloatingActionButton.small(
              tooltip: 'Выйти из полного экрана',
              onPressed: () => setState(() => _fullScreen = false),
              child: const Icon(Icons.fullscreen_exit_rounded),
            )
          : null,
      body: _loadError != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Text(_loadError!, textAlign: TextAlign.center),
              ),
            )
          : document == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: ColoredBox(
                    color: const Color(0xFFE7D7B9),
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: _deactivateDocxProgressScrub,
                      child: Builder(
                        builder: (context) {
                          final reader = Scrollbar(
                            controller: _scrollController,
                            thumbVisibility: true,
                            interactive: !Platform.isAndroid && !Platform.isIOS,
                            child: ListView(
                              scrollCacheExtent: const ScrollCacheExtent.pixels(3600),
                              controller: _scrollController,
                              padding: const EdgeInsets.fromLTRB(14, 18, 14, 32),
                              children: [_DocxPageView(document: document)],
                            ),
                          );
                          // Android/iOS selection over a scaled Office page can trigger platform-specific
                          // layout/paint failures. Keep the document visible on mobile and preserve
                          // desktop text selection; mobile still has the toolbar "copy all" action.
                          return _selectionAreaIsCheapForRichReader() ? SelectionArea(child: reader) : reader;
                        },
                      ),
                    ),
                  ),
                ),
                if (!_fullScreen)
                  _ContinuousReaderProgressBar(
                    progress: (_progress.clamp(0, 100) / 100).toDouble(),
                    label: '${_progress.clamp(0, 100).toStringAsFixed(1)}%',
                    active: _docxProgressScrubActive,
                    onActivate: () => setState(() => _docxProgressScrubActive = true),
                    onFractionSelected: _setDocxProgressFromFraction,
                  ),
              ],
            ),
    );
  }
}

class _DocxPageView extends StatelessWidget {
  const _DocxPageView({required this.document});

  final _Fb2Document document;

  List<_Fb2Block> _visibleBlocks() {
    // Keep explicit page-break markers in the flow. Earlier builds filtered them
    // out here, so the paginator ignored Word-declared page breaks and then
    // guessed page starts from rough height estimates.
    final result = document.blocks.toList(growable: false);
    if (result.any((block) => block.plainText.trim().isNotEmpty && block.plainText != _officePageBreakMarker)) {
      return result;
    }
    return const [
      _Fb2Block.paragraph([_Fb2Inline('DOCX открыт, но в документе не найдено отображаемое содержимое.')]),
    ];
  }

  List<List<_Fb2Block>> _buildPages() {
    final page = document.officePageFormat;
    final logicalBodyHeight = (page.logicalPageHeight - page.logicalTopMargin - page.logicalBottomMargin)
        .clamp(360.0, 1600.0)
        .toDouble();
    final headerReserve = document.officeHeaderBlocks.isEmpty ? 0.0 : 42.0;
    // Reserve a real footer band. A DOCX footer is not part of body flow: if the
    // paginator lets body blocks consume this band, text visually sticks to the
    // signature/footer line at the bottom of the page.
    final footerReserve = document.officeFooterBlocks.isEmpty ? 0.0 : 18.0;
    final usableHeight = (logicalBodyHeight - headerReserve - footerReserve + 44.0)
        .clamp(300.0, logicalBodyHeight)
        .toDouble();
    final usableWidth = (page.logicalPageWidth - page.logicalLeftMargin - page.logicalRightMargin)
        .clamp(260.0, 1400.0)
        .toDouble();

    final pages = <List<_Fb2Block>>[];
    var current = <_Fb2Block>[];
    var cursor = 0.0;

    void flush() {
      if (current.isEmpty) return;
      final hasVisibleContent = current.any((block) {
        if (block.kind == _Fb2BlockKind.image || block.kind == _Fb2BlockKind.table) return true;
        final text = block.plainText.replaceAll(_officePageBreakMarker, '').trim();
        return text.isNotEmpty;
      });
      // Keep intentional blank paragraphs inside a real page, but never create a
      // whole empty DOCX page from a run of section/page-break artifacts.
      if (hasVisibleContent) pages.add(List.unmodifiable(current));
      current = <_Fb2Block>[];
      cursor = 0.0;
    }

    for (final block in _visibleBlocks()) {
      if (block.plainText == _officePageBreakMarker) {
        flush();
        continue;
      }
      final estimate = _estimateDocxBlockHeight(block, usableWidth).clamp(12.0, usableHeight).toDouble();
      if (current.isNotEmpty && cursor + estimate > usableHeight) {
        flush();
      }
      current.add(block);
      cursor += estimate;
    }
    flush();
    if (pages.isEmpty) pages.add(_visibleBlocks());
    return pages;
  }

  double _estimateDocxBlockHeight(_Fb2Block block, double usableWidth) {
    switch (block.kind) {
      case _Fb2BlockKind.image:
        return 260;
      case _Fb2BlockKind.table:
        final rowCount = block.tableRows.length.clamp(1, 200).toInt();
        final maxCell = block.tableRows
            .expand((row) => row)
            .fold<int>(0, (max, cell) => cell.length > max ? cell.length : max);
        final extraLines = (maxCell / 42).ceil().clamp(0, 4).toInt();
        return 10.0 + rowCount * (16.0 + extraLines * 6.0);
      case _Fb2BlockKind.title:
      case _Fb2BlockKind.paragraph:
        final text = block.plainText.trim();
        final format = block.officeFormat;
        final fontSize = (format.fontSize <= 0 ? 11.0 : format.fontSize).clamp(8.0, 28.0).toDouble();
        final charsPerLine = (usableWidth / (fontSize * 0.48)).clamp(18.0, 120.0).toDouble();
        final hardLines = text.split('\n');
        var lines = 0;
        for (final line in hardLines) {
          final len = line.trimRight().isEmpty ? 1 : line.trimRight().length;
          lines += (len / charsPerLine).ceil().clamp(1, 80).toInt();
        }
        final lineHeight = fontSize * format.lineHeight.clamp(1.0, 2.4).toDouble();
        // Flutter text wrapping is slightly more compact than Word/Pages for
        // Times-like fonts; keep pagination conservative so pages do not absorb
        // too much text compared with a real DOCX viewer.
        return (format.spaceBefore + format.spaceAfter + lines * lineHeight) * 0.88;
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = _buildPages();
    final pageFormat = document.officePageFormat;
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportWidth = constraints.maxWidth.isFinite && constraints.maxWidth > 0
            ? constraints.maxWidth
            : MediaQuery.of(context).size.width;
        final available = (viewportWidth - 28).clamp(220.0, 2400.0).toDouble();
        final scale = (available / pageFormat.logicalPageWidth).clamp(0.42, 1.0).toDouble();
        final pageWidth = pageFormat.logicalPageWidth * scale;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (var index = 0; index < pages.length; index++)
              Padding(
                padding: EdgeInsets.only(bottom: index == pages.length - 1 ? 0 : 18),
                child: Center(
                  child: SizedBox(
                    width: pageWidth,
                    child: _DocxPaperPage(
                      document: document,
                      blocks: pages[index],
                      pageIndex: index,
                      pageCount: pages.length,
                      scale: scale,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _DocxPaperPage extends StatelessWidget {
  const _DocxPaperPage({
    required this.document,
    required this.blocks,
    required this.pageIndex,
    required this.pageCount,
    required this.scale,
  });

  final _Fb2Document document;
  final List<_Fb2Block> blocks;
  final int pageIndex;
  final int pageCount;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final page = document.officePageFormat;
    final fixedPageWidth = page.logicalPageWidth * scale;
    final minHeight = page.logicalPageHeight * scale;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE0E0E0), width: 0.8),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 22, offset: const Offset(0, 10)),
        ],
      ),
      child: ClipRect(
        child: SizedBox(
          width: fixedPageWidth,
          height: minHeight,
          child: Stack(
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  page.logicalLeftMargin * scale,
                  page.logicalTopMargin * scale,
                  page.logicalRightMargin * scale,
                  page.logicalBottomMargin * scale,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (document.officeHeaderBlocks.isNotEmpty)
                      _DocxHeaderFooterView(
                        blocks: document.officeHeaderBlocks,
                        isHeader: true,
                        pageIndex: pageIndex,
                        pageCount: pageCount,
                        scale: scale,
                      ),
                    for (final block in blocks) _DocxBlockView(block: block, scale: scale),
                    const Spacer(),
                    if (document.officeFooterBlocks.isNotEmpty) SizedBox(height: 16 * scale),
                    if (document.officeFooterBlocks.isNotEmpty)
                      _DocxHeaderFooterView(
                        blocks: document.officeFooterBlocks,
                        isHeader: false,
                        pageIndex: pageIndex,
                        pageCount: pageCount,
                        scale: scale,
                      ),
                  ],
                ),
              ),
              Positioned(
                top: (page.logicalTopMargin * 0.42).clamp(10.0, 34.0).toDouble() * scale,
                right: (page.logicalRightMargin * 0.48).clamp(12.0, 46.0).toDouble() * scale,
                child: Text(
                  '${pageIndex + 1}',
                  style: TextStyle(
                    color: const Color(0xFF777777),
                    fontSize: 8.6 * scale,
                    height: 1.0,
                    fontFamily: 'Times New Roman',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DocxHeaderFooterView extends StatelessWidget {
  const _DocxHeaderFooterView({
    required this.blocks,
    required this.isHeader,
    this.pageIndex = 0,
    this.pageCount = 1,
    this.scale = 1.0,
  });

  final List<_Fb2Block> blocks;
  final bool isHeader;
  final int pageIndex;
  final int pageCount;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final visible = _docxHeaderFooterVisibleBlocks(blocks, isHeader: isHeader);
    if (visible.isEmpty) return SizedBox(height: isHeader ? 4 * scale : 0);
    return Padding(
      padding: EdgeInsets.only(bottom: isHeader ? 14 * scale : 0, top: isHeader ? 0 : 6 * scale),
      child: DefaultTextStyle.merge(
        style: TextStyle(
          color: const Color(0xFF777777),
          fontSize: 8.8 * scale,
          height: 1.08,
          fontFamily: 'Times New Roman',
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [for (final block in visible) _DocxBlockView(block: block, compact: true, scale: scale)],
        ),
      ),
    );
  }
}

List<_Fb2Block> _docxHeaderFooterVisibleBlocks(List<_Fb2Block> blocks, {required bool isHeader}) {
  final result = <_Fb2Block>[];
  final seen = <String>{};
  for (final block in blocks) {
    final text = block.plainText.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) continue;
    // Word page-number fields often arrive as cached numeric runs. Rendering all
    // of them produced duplicated "12 / 1" artifacts in the page header. Until a
    // full field renderer is introduced, suppress numeric-only cached header runs.
    if (isHeader && RegExp(r'^\d{1,4}$').hasMatch(text)) continue;
    final fingerprint = '${block.kind}:$text'.toLowerCase();
    if (!seen.add(fingerprint)) continue;
    result.add(block);
  }
  return result;
}

class _DocxBlockView extends StatelessWidget {
  const _DocxBlockView({required this.block, this.compact = false, this.scale = 1.0});

  final _Fb2Block block;
  final bool compact;
  final double scale;

  @override
  Widget build(BuildContext context) {
    if (block.plainText == _officePageBreakMarker) return const SizedBox.shrink();
    switch (block.kind) {
      case _Fb2BlockKind.image:
        final bytes = block.imageBytes;
        if (bytes == null || bytes.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: EdgeInsets.symmetric(vertical: (compact ? 5 : 10) * scale),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: (compact ? 160 : 520) * scale),
              child: Image.memory(
                bytes,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined),
              ),
            ),
          ),
        );
      case _Fb2BlockKind.table:
        return _DocxDocumentTableView(
          rows: block.tableRows,
          format: block.officeTableFormat,
          compact: compact,
          scale: scale,
        );
      case _Fb2BlockKind.title:
      case _Fb2BlockKind.paragraph:
        final format = block.officeFormat;
        final isTitle = block.kind == _Fb2BlockKind.title || format.headingLevel > 0;
        final size = (compact ? (format.fontSize * 0.82).clamp(8.0, 12.0).toDouble() : format.fontSize) * scale;
        final style = TextStyle(
          color: compact ? const Color(0xFF777777) : const Color(0xFF111111),
          fontSize: isTitle && !compact ? size.clamp(12.5, 17.5).toDouble() : size,
          height: format.lineHeight,
          fontFamily: 'Times New Roman',
          fontWeight: isTitle || format.bold ? FontWeight.w700 : FontWeight.w400,
          fontStyle: format.italic ? FontStyle.italic : FontStyle.normal,
        );
        final listPrefix = compact ? null : format.listNumberText;
        final plain = block.plainText.replaceAll(RegExp(r'[ \t\u00A0]+'), ' ').trim();
        final cityDate = RegExp(r'^(г\.\s*[^0-9]+?)\s+(\d{1,2}\s+[А-Яа-яЁё]+\s+\d{4}\s*г\.?)$').firstMatch(plain);
        if (!compact && cityDate != null) {
          return Padding(
            padding: EdgeInsets.only(
              top: format.spaceBefore.clamp(0.0, 32.0).toDouble() * scale,
              bottom: format.spaceAfter.clamp(0.0, 32.0).toDouble() * scale,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    cityDate.group(1)!.trim(),
                    style: style.copyWith(fontWeight: FontWeight.w400),
                    textAlign: TextAlign.left,
                  ),
                ),
                Expanded(
                  child: Text(
                    cityDate.group(2)!.trim(),
                    style: style.copyWith(fontWeight: FontWeight.w400),
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
          );
        }
        final preserveLeadingWhitespace = RegExp(
          r'^\s*М\.?П\.?',
          caseSensitive: false,
        ).hasMatch(block.plainText.replaceAll('\u2003', ' '));
        final displayInlines = _docxDisplayInlines(block.inlines, preserveLeadingWhitespace: preserveLeadingWhitespace);
        final prefixShouldBeBold =
            isTitle ||
            format.bold ||
            displayInlines.where((inline) => inline.text.trim().isNotEmpty).every((inline) => inline.bold);
        final text = block.kind == _Fb2BlockKind.title
            ? TextSpan(text: block.plainText.trimLeft())
            : TextSpan(
                children: [
                  if (listPrefix != null && listPrefix.isNotEmpty)
                    TextSpan(
                      text: '$listPrefix ',
                      style: style.copyWith(
                        fontSize: isTitle && !compact ? size.clamp(12.5, 17.5).toDouble() : size,
                        fontWeight: prefixShouldBeBold ? FontWeight.w700 : style.fontWeight,
                      ),
                    ),
                  ...displayInlines.map((inline) => _docxInlineSpan(inline, format, compact: compact, scale: scale)),
                ],
              );
        // Word can express hanging indents with tab stops. Flutter Text cannot
        // reproduce that exactly in a single paragraph widget; applying raw
        // left/first-line indents created the visible DOCX "staircase". Keep the
        // body edge aligned and reserve only a tiny gutter for generated numbers.
        const leftIndent = 0.0;
        return Padding(
          padding: EdgeInsets.only(
            top: compact ? 0 : format.spaceBefore.clamp(0.0, 32.0).toDouble() * scale,
            bottom: (compact ? 2 : format.spaceAfter.clamp(0.0, 32.0).toDouble()) * scale,
            left: leftIndent * scale,
            right: compact ? 0 : format.rightIndent.clamp(0.0, 96.0).toDouble() * scale,
          ),
          child: Text.rich(text, style: style, textAlign: _officeTextAlign(format.align), softWrap: true),
        );
    }
  }
}

List<_Fb2Inline> _docxDisplayInlines(List<_Fb2Inline> source, {bool preserveLeadingWhitespace = false}) {
  if (source.isEmpty) return source;
  if (preserveLeadingWhitespace) return source;
  final result = <_Fb2Inline>[];
  var strippedLeading = false;
  for (final inline in source) {
    var text = inline.text;
    if (!strippedLeading) {
      final trimmed = text.replaceFirst(RegExp(r'^[ \t\u00A0]+'), '');
      if (trimmed.isEmpty) {
        result.add(
          _Fb2Inline(
            '',
            href: inline.href,
            bold: inline.bold,
            italic: inline.italic,
            underline: inline.underline,
            fontSize: inline.fontSize,
            fontFamily: inline.fontFamily,
            color: inline.color,
          ),
        );
        continue;
      }
      text = trimmed;
      strippedLeading = true;
    }
    result.add(
      _Fb2Inline(
        text,
        href: inline.href,
        bold: inline.bold,
        italic: inline.italic,
        underline: inline.underline,
        fontSize: inline.fontSize,
        fontFamily: inline.fontFamily,
        color: inline.color,
      ),
    );
  }
  return result.where((inline) => inline.text.isNotEmpty).toList(growable: false);
}

InlineSpan _docxInlineSpan(
  _Fb2Inline inline,
  _OfficeParagraphFormat format, {
  bool compact = false,
  double scale = 1.0,
}) {
  final size = (inline.fontSize ?? format.fontSize) * scale;
  return TextSpan(
    text: inline.text,
    style: TextStyle(
      color: compact ? const Color(0xFF777777) : (inline.color ?? const Color(0xFF111111)),
      fontSize: compact ? (size * 0.82).clamp(8.0, 12.0).toDouble() : size,
      fontFamily: inline.fontFamily ?? 'Times New Roman',
      fontWeight: inline.bold || format.bold ? FontWeight.w700 : FontWeight.w400,
      fontStyle: inline.italic || format.italic ? FontStyle.italic : FontStyle.normal,
      decoration: inline.underline ? TextDecoration.underline : TextDecoration.none,
    ),
  );
}

TextAlign _officeTextAlign(_OfficeTextAlign align) => switch (align) {
  _OfficeTextAlign.center => TextAlign.center,
  _OfficeTextAlign.right => TextAlign.right,
  _OfficeTextAlign.justify => TextAlign.justify,
  _OfficeTextAlign.left => TextAlign.left,
};

class _DocxDocumentTableView extends StatelessWidget {
  const _DocxDocumentTableView({required this.rows, this.format, this.compact = false, this.scale = 1.0});

  final List<List<String>> rows;
  final _OfficeTableFormat? format;
  final bool compact;
  final double scale;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    final columnCount = rows.fold<int>(0, (max, row) => row.length > max ? row.length : max).clamp(1, 24).toInt();
    final widths = _docxColumnWidths(rows, columnCount, format);
    final borderColor = compact ? const Color(0xFF999999) : Colors.black;
    final borderWidth = (compact ? 0.45 : 0.75) * scale;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: (compact ? 4 : 8) * scale),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: borderColor, width: borderWidth),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var rowIndex = 0; rowIndex < rows.length; rowIndex++)
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _buildRowCells(rowIndex, columnCount, widths, borderColor, borderWidth),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildRowCells(
    int rowIndex,
    int columnCount,
    List<double> widths,
    Color borderColor,
    double borderWidth,
  ) {
    final widgets = <Widget>[];
    final row = rows[rowIndex];
    var column = 0;
    while (column < columnCount) {
      final span = _officeCellSpanAt(format, rowIndex, column).clamp(0, columnCount - column).toInt();
      if (span == 0) {
        column += 1;
        continue;
      }
      final effectiveSpan = span <= 0 ? 1 : span;
      final text = column < row.length ? row[column] : '';
      final flex = widths
          .skip(column)
          .take(effectiveSpan)
          .fold<double>(0, (sum, value) => sum + value)
          .clamp(0.5, 100000.0);
      widgets.add(
        Expanded(
          flex: (flex * 1000).round().clamp(1, 1000000).toInt(),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(
                right: column + effectiveSpan >= columnCount
                    ? BorderSide.none
                    : BorderSide(color: borderColor, width: borderWidth),
                bottom: rowIndex == rows.length - 1
                    ? BorderSide.none
                    : BorderSide(color: borderColor, width: borderWidth),
              ),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: (compact ? 2.5 : 3.2) * scale,
                vertical: (compact ? 1.8 : 2.4) * scale,
              ),
              child: Text(
                text,
                textAlign: _docxTableCellAlign(text, rowIndex, column, columnCount, format),
                style: TextStyle(
                  color: compact ? const Color(0xFF777777) : Colors.black,
                  fontSize: (compact ? 8.5 : 10.2) * scale,
                  height: 1.08,
                  fontFamily: 'Times New Roman',
                  fontWeight: _docxTableCellShouldBeBold(rows, rowIndex, column, columnCount, format)
                      ? FontWeight.w700
                      : FontWeight.w400,
                  fontStyle: _docxTableCellShouldItalic(rows, rowIndex, column, format)
                      ? FontStyle.italic
                      : FontStyle.normal,
                ),
                softWrap: true,
              ),
            ),
          ),
        ),
      );
      column += effectiveSpan;
    }
    return widgets;
  }
}

int _officeCellSpanAt(_OfficeTableFormat? format, int row, int column) {
  if (format == null || row < 0 || row >= format.cellSpans.length) return 1;
  final line = format.cellSpans[row];
  if (column < 0 || column >= line.length) return 1;
  final value = line[column];
  return value <= 0 ? 0 : value;
}

TextAlign _docxTableCellAlign(String text, int rowIndex, int column, int columnCount, _OfficeTableFormat? format) {
  final explicit = _officeCellAlignAt(format, rowIndex, column);
  if (explicit != null) return _officeTextAlign(explicit);
  final trimmed = text.trim();
  if (trimmed.isEmpty) return TextAlign.center;
  if (rowIndex == 0) return TextAlign.center;
  if (RegExp(r'^(?:итого|итог|total)\b', caseSensitive: false).hasMatch(trimmed)) return TextAlign.right;
  if (RegExp(r'^[\d\s.,]+$').hasMatch(trimmed)) return TextAlign.center;
  // Fall back to Word-like defaults: text left, explicit numeric cells centered.
  return TextAlign.left;
}

bool _docxTableCellShouldBeBold(
  List<List<String>> rows,
  int rowIndex,
  int column,
  int columnCount,
  _OfficeTableFormat? format,
) {
  if (_officeCellFlagAt(format?.cellBold ?? const [], rowIndex, column)) return true;
  final text = column < rows[rowIndex].length ? rows[rowIndex][column].trim() : '';
  if (text.isEmpty) return false;
  if (rowIndex == 0) return true;
  if (RegExp(
    r'^(?:покупатель|поставщик|порядок расч|срок постав|грузополучател|существенные условия|итого)\b',
    caseSensitive: false,
  ).hasMatch(text)) {
    return true;
  }
  return false;
}

bool _docxTableCellShouldItalic(List<List<String>> rows, int rowIndex, int column, _OfficeTableFormat? format) {
  if (_officeCellFlagAt(format?.cellItalic ?? const [], rowIndex, column)) return true;
  if (column <= 0 || rowIndex <= 0) return false;
  final firstColumn = rows.map((row) => row.isEmpty ? '' : row.first.toLowerCase()).join(' ');
  return firstColumn.contains('порядок расч') ||
      firstColumn.contains('срок постав') ||
      firstColumn.contains('грузополучател') ||
      firstColumn.contains('существенные условия');
}

List<double> _docxColumnWidths(List<List<String>> rows, int columnCount, _OfficeTableFormat? format) {
  final grid = format?.columnTwips ?? const <int>[];
  if (grid.length >= columnCount && grid.take(columnCount).any((value) => value > 0)) {
    return [for (var index = 0; index < columnCount; index++) grid[index].clamp(240, 12000).toDouble()];
  }
  final weights = List<double>.filled(columnCount, 1.0);
  for (final row in rows) {
    for (var i = 0; i < columnCount; i++) {
      final cell = i < row.length ? row[i] : '';
      final longestWord = RegExp(r'\S+')
          .allMatches(cell)
          .fold<int>(0, (value, match) => match.group(0)!.length > value ? match.group(0)!.length : value);
      final textWeight = (cell.length / 18.0).clamp(1.0, 4.5).toDouble();
      weights[i] = weights[i] < textWeight ? textWeight : weights[i];
      if (longestWord > 16) weights[i] = weights[i] < 2.4 ? 2.4 : weights[i];
    }
  }
  return weights;
}

enum _RichSourceKind { fb2, epub, docx, doc, chm, djvu }

String _richFormatLabel(_RichSourceKind kind) => switch (kind) {
  _RichSourceKind.fb2 => 'FB2',
  _RichSourceKind.epub => 'EPUB',
  _RichSourceKind.docx => 'DOCX',
  _RichSourceKind.doc => 'DOC',
  _RichSourceKind.chm => 'CHM',
  _RichSourceKind.djvu => 'DJVU',
};

_Fb2Document _parseRichDocumentFromBytes(_RichSourceKind kind, Uint8List bytes) => switch (kind) {
  _RichSourceKind.epub => _parseEpubDocument(bytes),
  _RichSourceKind.docx => _parseDocxDocument(bytes),
  _RichSourceKind.doc => _parseDocDocument(bytes),
  _RichSourceKind.fb2 => _parseFb2Document(_decodeTextFile(bytes)),
  _RichSourceKind.chm => _makeFb2Document([
    _Fb2Block.paragraph([_Fb2Inline(_safeUnsupportedBinaryPreview('CHM'))]),
  ]),
  _RichSourceKind.djvu => _makeFb2Document([
    _Fb2Block.paragraph([_Fb2Inline(_safeUnsupportedBinaryPreview('DJVU'))]),
  ]),
};

Future<_Fb2Document> _parseReaderDocumentFromFileSafely({
  required _RichSourceKind kind,
  required File file,
  required _RichDocumentParseOperation operation,
}) async {
  final label = _richFormatLabel(kind);
  try {
    return await operation
        .parse(kind, file)
        .timeout(
          kind == _RichSourceKind.djvu ? const Duration(seconds: 75) : const Duration(seconds: 45),
          onTimeout: () {
            operation.cancel();
            throw TimeoutException('$label parsing timed out');
          },
        );
  } on TimeoutException {
    return _formatAdapterFailureDocument(
      label,
      'Подготовка файла заняла слишком много времени и была остановлена. Приложение продолжает работать; файл сохранён в библиотеке.',
    );
  } catch (error, stackTrace) {
    debugPrint('ReadArc $label adapter failed: $error\n$stackTrace');
    return _formatAdapterFailureDocument(label, 'Не удалось безопасно подготовить файл: $error');
  }
}

Future<_Fb2Document> _parseReaderDocumentFromFile({required _RichSourceKind kind, required File file}) async {
  switch (kind) {
    case _RichSourceKind.chm:
      return _parseChmDocumentFromFile(file);
    case _RichSourceKind.djvu:
      return _parseDjvuDocumentFromFile(file);
    case _RichSourceKind.fb2:
    case _RichSourceKind.epub:
    case _RichSourceKind.docx:
    case _RichSourceKind.doc:
      final length = await file.length();
      if (length > 256 * 1024 * 1024) {
        return _formatAdapterFailureDocument(
          _richFormatLabel(kind),
          'Файл слишком большой для текущего встроенного адаптера (${(length / (1024 * 1024)).toStringAsFixed(1)} MB).',
        );
      }
      return _parseRichDocumentFromBytes(kind, await file.readAsBytes());
  }
}

_Fb2Document _formatAdapterFailureDocument(String label, String message) {
  return _makeFb2Document([
    _Fb2Block.title(label),
    _Fb2Block.paragraph([_Fb2Inline(message)]),
    const _Fb2Block.paragraph([
      _Fb2Inline(
        'ReadArc больше не должен закрываться при ошибке адаптера. Для тяжёлых форматов будет использоваться pipeline processed artifacts: оригинал хранится в библиотеке, а подготовленное представление создаётся отдельно и безопасно переиспользуется на устройствах.',
      ),
    ]),
  ]);
}

bool _selectionAreaIsCheapForRichReader() => Platform.isMacOS || Platform.isWindows || Platform.isLinux;

class _Fb2ReaderScreen extends StatefulWidget {
  const _Fb2ReaderScreen({
    required this.book,
    required this.storage,
    required this.sync,
    this.sourceKind = _RichSourceKind.fb2,
  });

  final BookRecord book;
  final StorageService storage;
  final SyncService sync;
  final _RichSourceKind sourceKind;

  @override
  State<_Fb2ReaderScreen> createState() => _Fb2ReaderScreenState();
}

class _Fb2ReaderScreenState extends State<_Fb2ReaderScreen> {
  // FB2 reader v3: deterministic render units with exact extents.
  // The saved locator is blockIndex + unitInBlock, so reopening does not depend
  // on platform-specific scroll metrics or old absolute unit indices.
  static const _fontSize = 18.0;
  static const _heightFactor = 1.55;
  static const _lineExtent = _fontSize * _heightFactor;
  static const _titleExtent = 38.0;
  static const _imageExtent = 480.0;
  static const _coverImageExtent = 820.0;
  static const _horizontalReaderPadding = 22.0;
  static const _topPadding = 18.0;
  static const _bottomPadding = 28.0;
  static const _textStyle = TextStyle(fontSize: _fontSize, height: _heightFactor, color: Color(0xFF2F261F));
  static const _linkStyle = TextStyle(
    fontSize: _fontSize,
    height: _heightFactor,
    color: Color(0xFF7A4E1D),
    decoration: TextDecoration.underline,
  );

  final _scrollController = ScrollController();
  final _parseOperation = _RichDocumentParseOperation();
  BookRecord? _runtimeBook;
  _Fb2Document? _document;
  List<_Fb2RenderUnit>? _units;
  List<double> _unitOffsets = const [];
  double _lastUsableWidth = 0;
  _Fb2UnitLocator? _lastKnownLocator;
  String? _loadError;
  Timer? _saveDebounce;
  Timer? _layoutDebounce;
  Timer? _progressRedrawThrottle;
  double _progress = 0;
  int _pendingUnitIndex = 0;
  bool _restoringPosition = false;
  bool _didInitialRestore = false;
  bool _fullScreen = false;
  bool _richProgressScrubActive = false;

  BookRecord get _book => _runtimeBook ?? widget.book;

  @override
  void initState() {
    super.initState();
    _progress = widget.book.progressPercent;
    _scrollController.addListener(_onScroll);
    unawaited(_load());
  }

  @override
  void dispose() {
    _parseOperation.cancel();
    _layoutDebounce?.cancel();
    _saveDebounce?.cancel();
    _progressRedrawThrottle?.cancel();
    final locator = _lastKnownLocator ?? _currentLocator();
    if (locator != null) unawaited(_saveProgress(locator));
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final manifest = await widget.storage.loadManifest();
    var book = widget.book;
    for (final candidate in manifest.books) {
      if (candidate.id == widget.book.id) {
        book = candidate;
        break;
      }
    }
    final formatLabel = switch (widget.sourceKind) {
      _RichSourceKind.epub => 'EPUB',
      _RichSourceKind.docx => 'DOCX',
      _RichSourceKind.doc => 'DOC',
      _RichSourceKind.chm => 'CHM',
      _RichSourceKind.djvu => 'DJVU',
      _RichSourceKind.fb2 => 'FB2',
    };
    if (book.localPath == null) {
      if (mounted) setState(() => _loadError = 'Файл $formatLabel не скачан на это устройство');
      return;
    }
    final file = File(book.localPath!);
    if (!await file.exists()) {
      if (mounted) setState(() => _loadError = 'Файл $formatLabel отсутствует: ${book.localPath}');
      return;
    }
    try {
      final document = await _parseReaderDocumentFromFileSafely(
        kind: widget.sourceKind,
        file: file,
        operation: _parseOperation,
      );
      if (!mounted) return;
      setState(() {
        _runtimeBook = book;
        _document = document;
        _loadError = null;
      });
    } catch (error) {
      if (mounted) setState(() => _loadError = 'Не удалось открыть $formatLabel: $error');
    }
  }

  void _ensureUnitsForWidth(double maxWidth) {
    final document = _document;
    if (document == null) return;
    final usableWidth = (maxWidth - (_horizontalReaderPadding * 2)).clamp(180.0, 2000.0).toDouble();
    if (_units != null && (usableWidth - _lastUsableWidth).abs() < 8) return;

    final current = _currentLocator() ?? _lastKnownLocator;
    final built = _buildFb2RenderUnits(document, usableWidth);
    final units = built.isEmpty
        ? [
            const _Fb2RenderUnit.text([_Fb2LineSegment('')], 0, 0, false, 0, 0),
          ]
        : built;
    final target = _didInitialRestore && current != null
        ? _targetUnitForLocator(current, units)
        : _targetUnitForBook(_book, units);

    _layoutDebounce?.cancel();
    setState(() {
      _units = units;
      _unitOffsets = _buildFb2UnitOffsets(units);
      _lastUsableWidth = usableWidth;
      _pendingUnitIndex = target.clamp(0, units.length - 1).toInt();
      _lastKnownLocator = _locatorForUnit(_pendingUnitIndex);
      _progress = _lastKnownLocator?.progressPercent ?? 0;
    });
    _scheduleRestoreScroll();
  }

  int _targetUnitForBook(BookRecord book, List<_Fb2RenderUnit> units) {
    if (units.isEmpty) return 0;
    final progress = book.progressPercent.clamp(0.0, 100.0).toDouble();
    int byProgress() {
      final document = _document;
      final totalChars = document?.totalTextChars ?? 0;
      if (totalChars > 1) {
        final anchor = ((progress / 100.0) * (totalChars - 1)).round().clamp(0, totalChars - 1).toInt();
        return _unitIndexForAnchorChar(anchor, units);
      }
      return ((progress / 100.0) * (units.length - 1)).round().clamp(0, units.length - 1).toInt();
    }

    try {
      final decoded = jsonDecode(book.currentLocator);
      if (decoded is Map) {
        final type = decoded['type'];
        final locatorProgress = (decoded['progressPercent'] as num?)?.toDouble();
        final anchorChar = (decoded['anchorChar'] as num?)?.round();
        final totalChars = (_document?.totalTextChars ?? (decoded['totalChars'] as num?)?.round() ?? 0);
        if ((type == 'fb2-unit-anchor-v4' ||
                type == 'epub-unit-anchor-v2' ||
                type == 'docx-unit-anchor-v1' ||
                type == 'chm-unit-anchor-v1' ||
                type == 'djvu-unit-anchor-v1') &&
            anchorChar != null) {
          return _unitIndexForAnchorChar(anchorChar.clamp(0, totalChars > 0 ? totalChars : 1 << 30).toInt(), units);
        }
        // If manifest.progressPercent and currentLocator disagree, trust the
        // manifest progress. Also trust progress when the locator was saved on
        // a different screen width: unitInBlock is a wrapped-line number and is
        // not stable between macOS/Android. This fixes cases like 2.4% synced
        // in the list but reopening on Android jumping back to 1.4%.
        final locatorWidth = (decoded['usableWidth'] as num?)?.toDouble();
        final savedUnitCount = (decoded['unitCount'] as num?)?.round();
        final widthChanged =
            locatorWidth != null && _lastUsableWidth > 0 && (locatorWidth - _lastUsableWidth).abs() > 16;
        final unitCountChanged =
            savedUnitCount != null &&
            savedUnitCount > 0 &&
            ((savedUnitCount - units.length).abs() / units.length) > 0.04;
        if ((locatorProgress != null && (locatorProgress - progress).abs() > 0.75) ||
            widthChanged ||
            unitCountChanged) {
          return byProgress();
        }

        if (type == 'fb2-unit-anchor-v3' || type == 'fb2-unit-anchor-v2' || type == 'epub-unit-anchor-v1') {
          final unitIndex = (decoded['unitIndex'] as num?)?.round();
          final unitCount = (decoded['unitCount'] as num?)?.round();
          if (unitIndex != null && unitCount != null && unitCount > 0) {
            final ratioDiff = ((unitCount - units.length).abs() / units.length).abs();
            if (ratioDiff < 0.04) {
              return unitIndex.clamp(0, units.length - 1).toInt();
            }
          }
          final blockIndex = (decoded['blockIndex'] as num?)?.round();
          final unitInBlock = (decoded['unitInBlock'] as num?)?.round();
          if (blockIndex != null && unitInBlock != null) {
            final idx = units.indexWhere((unit) => unit.blockIndex == blockIndex && unit.unitInBlock == unitInBlock);
            if (idx >= 0) return idx;
          }
          return byProgress();
        }
        if (type == 'fb2-unit-anchor-v1') {
          return ((decoded['unitIndex'] as num?)?.round() ?? byProgress()).clamp(0, units.length - 1).toInt();
        }
        if (type == 'fb2-block-anchor-v1') {
          final blockIndex = ((decoded['blockIndex'] as num?)?.round() ?? 0).clamp(0, 1000000).toInt();
          final idx = units.indexWhere((unit) => unit.blockIndex >= blockIndex);
          return (idx < 0 ? byProgress() : idx).clamp(0, units.length - 1).toInt();
        }
        if (type == 'fb2-line-anchor-v1') {
          final lineIndex = ((decoded['lineIndex'] as num?)?.round() ?? byProgress())
              .clamp(0, units.length - 1)
              .toInt();
          return lineIndex;
        }
      }
    } catch (_) {}
    return byProgress();
  }

  int _targetUnitForLocator(_Fb2UnitLocator locator, List<_Fb2RenderUnit> units) {
    if (locator.anchorChar > 0) return _unitIndexForAnchorChar(locator.anchorChar, units);
    final idx = units.indexWhere(
      (unit) => unit.blockIndex == locator.blockIndex && unit.unitInBlock == locator.unitInBlock,
    );
    if (idx >= 0) return idx;
    return locator.unitIndex.clamp(0, units.length - 1).toInt();
  }

  int _unitIndexForAnchorChar(int anchorChar, List<_Fb2RenderUnit> units) {
    if (units.isEmpty) return 0;
    final safeAnchor = anchorChar.clamp(0, 1 << 30).toInt();
    var low = 0;
    var high = units.length - 1;
    while (low <= high) {
      final mid = low + ((high - low) >> 1);
      final unit = units[mid];
      if (safeAnchor < unit.anchorChar) {
        high = mid - 1;
      } else if (safeAnchor >= unit.endChar && unit.endChar > unit.anchorChar) {
        low = mid + 1;
      } else {
        return mid;
      }
    }
    return low.clamp(0, units.length - 1).toInt();
  }

  void _scheduleRestoreScroll() {
    final units = _units;
    if (units == null || units.isEmpty) return;
    _restoringPosition = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final target = _offsetForUnit(_pendingUnitIndex);
        var jumped = false;
        for (var attempt = 0; attempt < 20; attempt++) {
          await Future<void>.delayed(Duration(milliseconds: attempt == 0 ? 16 : 35));
          if (!mounted || !_scrollController.hasClients) continue;
          final position = _scrollController.position;
          if (!position.hasContentDimensions) continue;
          final max = position.maxScrollExtent;
          if (target > max + 4 && attempt < 12) continue;
          _scrollController.jumpTo(target.clamp(0.0, max));
          jumped = true;
          break;
        }
        if (!jumped && mounted && _scrollController.hasClients) {
          _scrollController.jumpTo(
            _offsetForUnit(_pendingUnitIndex).clamp(0.0, _scrollController.position.maxScrollExtent),
          );
        }
        final locator = _currentLocator() ?? _locatorForUnit(_pendingUnitIndex);
        _lastKnownLocator = locator;
        _progress = locator?.progressPercent ?? _progress;
        _didInitialRestore = true;
        if (mounted) setState(() {});
      } finally {
        _restoringPosition = false;
      }
    });
  }

  _Fb2UnitLocator? _currentLocator() {
    final units = _units;
    if (units == null || units.isEmpty) return null;
    if (!_scrollController.hasClients) {
      return _lastKnownLocator ?? _locatorForUnit(_pendingUnitIndex.clamp(0, units.length - 1).toInt());
    }
    if (_scrollController.position.maxScrollExtent <= 0 || _scrollController.position.extentAfter <= 8) {
      return _locatorForUnit(units.length - 1);
    }
    final unitIndex = _unitIndexForOffset(_scrollController.offset).clamp(0, units.length - 1).toInt();
    return _locatorForUnit(unitIndex);
  }

  _Fb2UnitLocator? _locatorForUnit(int unitIndex) {
    final units = _units;
    if (units == null || units.isEmpty) return null;
    final safe = unitIndex.clamp(0, units.length - 1).toInt();
    final unit = units[safe];
    return _Fb2UnitLocator(
      unitIndex: safe,
      unitCount: units.length,
      blockIndex: unit.blockIndex,
      unitInBlock: unit.unitInBlock,
      anchorChar: unit.anchorChar,
      totalChars: _document?.totalTextChars ?? 0,
      scrollOffset: _scrollController.hasClients ? _scrollController.offset : null,
      totalExtent: _unitOffsets.isEmpty ? null : (_unitOffsets.last + units.last.extent + _bottomPadding),
      usableWidth: _lastUsableWidth,
    );
  }

  int _unitIndexForOffset(double offset) {
    final offsets = _unitOffsets;
    final units = _units;
    if (offsets.isEmpty || units == null || units.isEmpty) return 0;
    var lo = 0;
    var hi = offsets.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (offsets[mid] <= offset) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return hi.clamp(0, units.length - 1).toInt();
  }

  double _offsetForUnit(int unitIndex) {
    if (_unitOffsets.isEmpty) return 0;
    final safe = unitIndex.clamp(0, _unitOffsets.length - 1).toInt();
    return _unitOffsets[safe];
  }

  void _onScroll() {
    if (_restoringPosition || !_didInitialRestore || !_scrollController.hasClients) return;
    final locator = _currentLocator();
    if (locator == null) return;
    _lastKnownLocator = locator;
    _pendingUnitIndex = locator.unitIndex;
    _progress = locator.progressPercent;
    if (!(_progressRedrawThrottle?.isActive ?? false)) {
      _progressRedrawThrottle = Timer(const Duration(milliseconds: 140), () {
        if (mounted) setState(() {});
      });
    }
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 1100), () {
      unawaited(_saveProgress(locator));
    });
  }

  void _setRichProgressFromFraction(double fraction) {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final target = (position.maxScrollExtent * fraction.clamp(0.0, 1.0))
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    _scrollController.jumpTo(target);
    final locator = _currentLocator();
    if (locator != null) {
      _lastKnownLocator = locator;
      _pendingUnitIndex = locator.unitIndex;
      _progress = locator.progressPercent;
      _saveDebounce?.cancel();
      _saveDebounce = Timer(const Duration(milliseconds: 450), () => unawaited(_saveProgress(locator)));
    }
    if (mounted) setState(() {});
  }

  void _deactivateRichProgressScrub() {
    if (_richProgressScrubActive) setState(() => _richProgressScrubActive = false);
  }

  Future<void> _saveProgress(_Fb2UnitLocator locator) async {
    _lastKnownLocator = locator;
    _pendingUnitIndex = locator.unitIndex;
    _progress = locator.progressPercent;
    final manifest = await widget.storage.updateProgress(
      bookId: widget.book.id,
      progressPercent: locator.progressPercent,
      locator: locator.toJsonString(
        type: switch (widget.sourceKind) {
          _RichSourceKind.epub => 'epub-unit-anchor-v2',
          _RichSourceKind.docx => 'docx-unit-anchor-v1',
          _RichSourceKind.doc => 'doc-unit-anchor-v1',
          _RichSourceKind.chm => 'chm-unit-anchor-v1',
          _RichSourceKind.djvu => 'djvu-unit-anchor-v1',
          _RichSourceKind.fb2 => 'fb2-unit-anchor-v4',
        },
      ),
    );
    for (final book in manifest.books) {
      if (book.id == widget.book.id) {
        _runtimeBook = book;
        break;
      }
    }
    await widget.sync.broadcastLibrarySnapshot(reason: 'progress_updated');
  }

  Future<void> _addBookmark() async {
    final locator = _currentLocator();
    await widget.storage.addBookmark(
      bookId: widget.book.id,
      label: 'Закладка ${DateTime.now().toLocal().toIso8601String().substring(0, 16)}',
      locator:
          locator?.toJsonString(
            type: switch (widget.sourceKind) {
              _RichSourceKind.epub => 'epub-unit-anchor-v2',
              _RichSourceKind.docx => 'docx-unit-anchor-v1',
              _RichSourceKind.doc => 'doc-unit-anchor-v1',
              _RichSourceKind.chm => 'chm-unit-anchor-v1',
              _RichSourceKind.djvu => 'djvu-unit-anchor-v1',
              _RichSourceKind.fb2 => 'fb2-unit-anchor-v4',
            },
          ) ??
          _book.currentLocator,
    );
    await widget.sync.broadcastLibrarySnapshot(reason: 'bookmark_added');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Закладка добавлена')));
  }

  Future<void> _copyVisibleText() async {
    final units = _units;
    if (units == null || units.isEmpty) return;
    final current = _currentLocator();
    final start = (current?.unitIndex ?? 0).clamp(0, units.length - 1).toInt();
    final buffer = StringBuffer();
    var copied = 0;
    for (var i = start; i < units.length && copied < 40; i++) {
      final unit = units[i];
      if (unit.imageBytes != null) continue;
      final text = unit.tableRows.isNotEmpty
          ? unit.tableRows.map((row) => row.join('\t')).join('\n')
          : unit.segments.map((segment) => segment.text).join('').trimRight();
      if (text.isEmpty) continue;
      buffer.writeln(text);
      copied += 1;
    }
    final text = buffer.toString().trimRight();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Скопирован фрагмент ${_richFormatLabel(widget.sourceKind)} ($copied строк)')),
    );
  }

  Future<void> _openExternalLink(String href) async {
    final trimmed = href.trim();
    if (trimmed.isEmpty) return;
    final uri = Uri.tryParse(trimmed);
    final isExternal = uri != null && uri.hasScheme && uri.scheme.toLowerCase() != 'file';
    if (!isExternal) {
      final target = _internalLinkTargetFor(trimmed);
      final units = _units;
      if (target != null && units != null && units.isNotEmpty && _scrollController.hasClients) {
        final unitIndex = units.indexWhere((unit) => unit.blockIndex >= target);
        final safe = (unitIndex < 0 ? units.length - 1 : unitIndex).clamp(0, units.length - 1).toInt();
        _pendingUnitIndex = safe;
        _restoringPosition = true;
        try {
          // Internal EPUB links are block/unit anchors, not percentages.
          // Jump to the exact rendered unit and only then save that exact locator.
          // Progress is derived from the unit, so it cannot show the right percent
          // while the viewport remains a few lines above or below the target.
          final targetLocator = _locatorForUnit(safe);
          for (var attempt = 0; attempt < 12; attempt++) {
            await Future<void>.delayed(Duration(milliseconds: attempt == 0 ? 0 : 24));
            if (!mounted || !_scrollController.hasClients) continue;
            final position = _scrollController.position;
            if (!position.hasContentDimensions) continue;
            final max = position.maxScrollExtent;
            final offset = _offsetForUnit(safe).clamp(0.0, max).toDouble();
            _scrollController.jumpTo(offset);
            break;
          }
          final locator = targetLocator ?? _currentLocator();
          if (locator != null) {
            _lastKnownLocator = locator;
            _pendingUnitIndex = locator.unitIndex;
            _progress = locator.progressPercent;
            await _saveProgress(locator);
            if (mounted) setState(() {});
          }
        } finally {
          _restoringPosition = false;
        }
        return;
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не найден якорь: $href')));
      return;
    }
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось открыть ссылку: $href')));
    }
  }

  int? _internalLinkTargetFor(String href) {
    final document = _document;
    if (document == null || document.linkTargets.isEmpty) return null;
    final candidates = _internalHrefLookupCandidates(href);
    for (final key in candidates) {
      final target = document.linkTargets[key];
      if (target != null) return target;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final document = _document;
    final units = _units;
    return Scaffold(
      backgroundColor: const Color(0xFFF3E7CF),
      appBar: _fullScreen
          ? null
          : AppBar(
              title: Text(_book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              actions: [
                IconButton(
                  tooltip: 'Полный экран',
                  onPressed: () => setState(() => _fullScreen = true),
                  icon: const Icon(Icons.fullscreen_rounded),
                ),
                IconButton(
                  tooltip: 'Скопировать видимый фрагмент',
                  onPressed: units != null ? _copyVisibleText : null,
                  icon: const Icon(Icons.copy_all_rounded),
                ),
                IconButton(
                  tooltip: 'Добавить закладку',
                  onPressed: units != null ? _addBookmark : null,
                  icon: const Icon(Icons.bookmark_add_outlined),
                ),
              ],
            ),
      floatingActionButton: _fullScreen
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton.small(
                  heroTag: 'fb2-copy-${widget.book.id}',
                  tooltip: 'Скопировать видимый фрагмент',
                  onPressed: units != null ? _copyVisibleText : null,
                  child: const Icon(Icons.copy_all_rounded),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'fb2-bookmark-${widget.book.id}',
                  tooltip: 'Добавить закладку',
                  onPressed: units != null ? _addBookmark : null,
                  child: const Icon(Icons.bookmark_add_outlined),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'fb2-exit-fullscreen-${widget.book.id}',
                  tooltip: 'Выйти из полного экрана',
                  onPressed: () => setState(() => _fullScreen = false),
                  child: const Icon(Icons.fullscreen_exit_rounded),
                ),
              ],
            )
          : null,
      body: _loadError != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Text(_loadError!, textAlign: TextAlign.center),
              ),
            )
          : document == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      _ensureUnitsForWidth(constraints.maxWidth);
                      final currentUnits = _units;
                      if (currentUnits == null) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      final readerList = ListView.builder(
                        scrollCacheExtent: const ScrollCacheExtent.pixels(_lineExtent * 220),
                        controller: _scrollController,
                        padding: const EdgeInsets.fromLTRB(
                          _horizontalReaderPadding,
                          _topPadding,
                          _horizontalReaderPadding,
                          _bottomPadding,
                        ),
                        itemExtentBuilder: (index, dimensions) => currentUnits[index].extent,
                        itemCount: currentUnits.length,
                        itemBuilder: (context, index) {
                          final unit = currentUnits[index];
                          return RepaintBoundary(
                            child: _Fb2UnitView(unit: unit, onOpenLink: _openExternalLink),
                          );
                        },
                      );
                      return GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: _deactivateRichProgressScrub,
                        child: Scrollbar(
                          controller: _scrollController,
                          thumbVisibility: true,
                          interactive: !Platform.isAndroid && !Platform.isIOS,
                          child: _selectionAreaIsCheapForRichReader() ? SelectionArea(child: readerList) : readerList,
                        ),
                      );
                    },
                  ),
                ),
                if (!_fullScreen)
                  _ContinuousReaderProgressBar(
                    progress: (_progress.clamp(0, 100) / 100).toDouble(),
                    label: '${_progress.clamp(0, 100).toStringAsFixed(1)}%',
                    active: _richProgressScrubActive,
                    onActivate: () => setState(() => _richProgressScrubActive = true),
                    onFractionSelected: _setRichProgressFromFraction,
                  ),
              ],
            ),
    );
  }
}

class _Fb2UnitView extends StatelessWidget {
  const _Fb2UnitView({required this.unit, required this.onOpenLink});

  final _Fb2RenderUnit unit;
  final ValueChanged<String> onOpenLink;

  @override
  Widget build(BuildContext context) {
    if (unit.tableRows.isNotEmpty) {
      return _DocxTableUnitView(rows: unit.tableRows, extent: unit.extent);
    }

    if (unit.imageBytes != null) {
      final bytes = unit.imageBytes!;
      return SizedBox(
        height: unit.extent,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Image.memory(
            bytes,
            fit: BoxFit.contain,
            alignment: Alignment.center,
            width: double.infinity,
            height: unit.extent - 16,
            errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined),
          ),
        ),
      );
    }

    final style = unit.isTitle
        ? const TextStyle(fontSize: 19, height: 1.45, fontWeight: FontWeight.w700, color: Color(0xFF2F261F))
        : _Fb2ReaderScreenState._textStyle;
    return SizedBox(
      height: unit.extent,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text.rich(
          TextSpan(
            style: style,
            children: unit.segments.map((segment) {
              final href = segment.href;
              final segmentStyle = TextStyle(
                fontWeight: segment.bold ? FontWeight.w700 : null,
                fontStyle: segment.italic ? FontStyle.italic : null,
                decoration: segment.underline ? TextDecoration.underline : null,
              );
              if (href == null || href.isEmpty) return TextSpan(text: segment.text, style: segmentStyle);
              return TextSpan(
                text: segment.text,
                style: _Fb2ReaderScreenState._linkStyle.merge(segmentStyle),
                recognizer: TapGestureRecognizer()..onTap = () => onOpenLink(href),
              );
            }).toList(),
          ),
          maxLines: 1,
        ),
      ),
    );
  }
}

class _DocxTableUnitView extends StatelessWidget {
  const _DocxTableUnitView({required this.rows, required this.extent});

  final List<List<String>> rows;
  final double extent;

  @override
  Widget build(BuildContext context) {
    final columnCount = rows.fold<int>(0, (max, row) => row.length > max ? row.length : max).clamp(1, 24).toInt();
    return SizedBox(
      height: extent,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFFFFF7E8),
            border: Border.all(color: const Color(0xFFC9AA78).withValues(alpha: 0.65)),
            borderRadius: BorderRadius.circular(14),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: MediaQuery.of(context).size.width - 56),
                child: Table(
                  defaultColumnWidth: const IntrinsicColumnWidth(),
                  border: TableBorder.symmetric(
                    inside: BorderSide(color: const Color(0xFFC9AA78).withValues(alpha: 0.35)),
                  ),
                  children: [
                    for (var rowIndex = 0; rowIndex < rows.length; rowIndex++)
                      TableRow(
                        decoration: BoxDecoration(
                          color: rowIndex == 0 ? const Color(0xFFF0DBAE).withValues(alpha: 0.45) : Colors.transparent,
                        ),
                        children: [
                          for (var column = 0; column < columnCount; column++)
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                              child: Text(
                                column < rows[rowIndex].length ? rows[rowIndex][column] : '',
                                style: TextStyle(
                                  fontSize: 15.5,
                                  height: 1.35,
                                  color: const Color(0xFF2A2F4A),
                                  fontWeight: rowIndex == 0 ? FontWeight.w600 : FontWeight.w400,
                                ),
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Fb2LineSegment {
  const _Fb2LineSegment(this.text, {this.href, this.bold = false, this.italic = false, this.underline = false});

  final String text;
  final String? href;
  final bool bold;
  final bool italic;
  final bool underline;
}

class _Fb2RenderUnit {
  const _Fb2RenderUnit.text(
    this.segments,
    this.blockIndex,
    this.unitInBlock,
    this.isTitle,
    this.anchorChar,
    this.endChar,
  ) : imageBytes = null,
      tableRows = const [],
      extent = isTitle ? _Fb2ReaderScreenState._titleExtent : _Fb2ReaderScreenState._lineExtent;

  const _Fb2RenderUnit.image(this.imageBytes, this.blockIndex, this.unitInBlock, this.anchorChar, this.endChar)
    : segments = const [],
      tableRows = const [],
      isTitle = false,
      extent = blockIndex == 0 ? _Fb2ReaderScreenState._coverImageExtent : _Fb2ReaderScreenState._imageExtent;

  _Fb2RenderUnit.table(this.tableRows, this.blockIndex, this.unitInBlock, this.anchorChar, this.endChar)
    : segments = const [],
      imageBytes = null,
      isTitle = false,
      extent = _tableExtent(tableRows);

  static double _tableExtent(List<List<String>> rows) {
    if (rows.isEmpty) return _Fb2ReaderScreenState._lineExtent;
    final widest = rows.expand((row) => row).fold<int>(0, (max, cell) => cell.length > max ? cell.length : max);
    final extraForWrappedCells = (widest / 48).floor().clamp(0, 4) * 14.0;
    return (rows.length * (38.0 + extraForWrappedCells) + 22.0).clamp(58.0, 520.0).toDouble();
  }

  final List<_Fb2LineSegment> segments;
  final Uint8List? imageBytes;
  final List<List<String>> tableRows;
  final int blockIndex;
  final int unitInBlock;
  final bool isTitle;
  final int anchorChar;
  final int endChar;
  final double extent;
}

class _Fb2UnitLocator {
  const _Fb2UnitLocator({
    required this.unitIndex,
    required this.unitCount,
    required this.blockIndex,
    required this.unitInBlock,
    required this.anchorChar,
    required this.totalChars,
    this.scrollOffset,
    this.totalExtent,
    this.usableWidth,
  });

  final int unitIndex;
  final int unitCount;
  final int blockIndex;
  final int unitInBlock;
  final int anchorChar;
  final int totalChars;
  final double? scrollOffset;
  final double? totalExtent;
  final double? usableWidth;

  double get progressPercent {
    if (totalChars > 1) return ((anchorChar / (totalChars - 1)) * 100).clamp(0.0, 100.0).toDouble();
    if (unitCount <= 1) return unitCount == 1 && unitIndex > 0 ? 100 : 0;
    return ((unitIndex / (unitCount - 1)) * 100).clamp(0.0, 100.0).toDouble();
  }

  String toJsonString({String type = 'fb2-unit-anchor-v4'}) => jsonEncode({
    'type': type,
    'unitIndex': unitIndex,
    'unitCount': unitCount,
    'blockIndex': blockIndex,
    'unitInBlock': unitInBlock,
    'anchorChar': anchorChar,
    'totalChars': totalChars,
    'scrollOffset': scrollOffset,
    'totalExtent': totalExtent,
    'usableWidth': usableWidth,
    'progressPercent': progressPercent,
    'updatedAt': DateTime.now().toUtc().toIso8601String(),
  });
}

List<_Fb2RenderUnit> _buildFb2RenderUnits(_Fb2Document document, double usableWidth) {
  final units = <_Fb2RenderUnit>[];
  final charsPerLine = (usableWidth / (_Fb2ReaderScreenState._fontSize * 0.56)).floor().clamp(24, 140).toInt();
  for (var blockIndex = 0; blockIndex < document.blocks.length; blockIndex++) {
    final block = document.blocks[blockIndex];
    final blockStartChar = document.startCharForBlock(blockIndex);
    final blockEndChar = document.endCharForBlock(blockIndex);
    switch (block.kind) {
      case _Fb2BlockKind.image:
        final bytes = block.imageBytes;
        if (bytes != null && bytes.isNotEmpty) {
          units.add(_Fb2RenderUnit.image(bytes, blockIndex, 0, blockStartChar, blockEndChar));
        }
        break;
      case _Fb2BlockKind.table:
        if (block.tableRows.isNotEmpty) {
          units.add(_Fb2RenderUnit.table(block.tableRows, blockIndex, 0, blockStartChar, blockEndChar));
        }
        break;
      case _Fb2BlockKind.title:
        units.addAll(
          _wrapFb2Segments([_Fb2LineSegment(block.plainText)], blockIndex, true, charsPerLine, blockStartChar),
        );
        break;
      case _Fb2BlockKind.paragraph:
        final segments = block.inlines
            .map(
              (inline) => _Fb2LineSegment(
                inline.text,
                href: inline.href,
                bold: inline.bold,
                italic: inline.italic,
                underline: inline.underline,
              ),
            )
            .toList();
        units.addAll(_wrapFb2Segments(segments, blockIndex, false, charsPerLine, blockStartChar));
        break;
    }
  }
  return units;
}

List<_Fb2RenderUnit> _wrapFb2Segments(
  List<_Fb2LineSegment> source,
  int blockIndex,
  bool isTitle,
  int charsPerLine,
  int blockStartChar,
) {
  final result = <_Fb2RenderUnit>[];
  final current = <_Fb2LineSegment>[];
  var currentLen = 0;
  var unitInBlock = 0;
  var cursor = blockStartChar;
  var unitStartChar = blockStartChar;
  var unitEndChar = blockStartChar;

  void flush() {
    if (current.isEmpty) return;
    final normalized = current.where((segment) => segment.text.isNotEmpty).toList();
    if (normalized.isNotEmpty) {
      result.add(
        _Fb2RenderUnit.text(
          List.unmodifiable(normalized),
          blockIndex,
          unitInBlock,
          isTitle,
          unitStartChar,
          unitEndChar,
        ),
      );
      unitInBlock += 1;
    }
    current.clear();
    currentLen = 0;
    unitStartChar = cursor;
    unitEndChar = cursor;
  }

  for (final segment in source) {
    var text = segment.text.replaceAll(RegExp(r'\s+'), ' ');
    while (text.isNotEmpty) {
      final remaining = charsPerLine - currentLen;
      if (remaining <= 0) {
        flush();
        continue;
      }
      if (current.isEmpty) unitStartChar = cursor;
      if (text.length <= remaining) {
        current.add(
          _Fb2LineSegment(
            text,
            href: segment.href,
            bold: segment.bold,
            italic: segment.italic,
            underline: segment.underline,
          ),
        );
        currentLen += text.length;
        cursor += text.length;
        unitEndChar = cursor;
        text = '';
      } else {
        var cut = text.lastIndexOf(' ', remaining);
        if (cut <= 0 || cut < remaining * 0.45) cut = remaining;
        final part = text.substring(0, cut).trimRight();
        if (part.isNotEmpty) {
          current.add(
            _Fb2LineSegment(
              part,
              href: segment.href,
              bold: segment.bold,
              italic: segment.italic,
              underline: segment.underline,
            ),
          );
          currentLen += part.length;
          cursor += part.length;
          unitEndChar = cursor;
        }
        flush();
        final rest = text.substring(cut);
        final trimmedRest = rest.trimLeft();
        cursor += rest.length - trimmedRest.length;
        text = trimmedRest;
      }
    }
  }
  flush();
  return result;
}

List<double> _buildFb2UnitOffsets(List<_Fb2RenderUnit> units) {
  final offsets = <double>[];
  var offset = _Fb2ReaderScreenState._topPadding;
  for (final unit in units) {
    offsets.add(offset);
    offset += unit.extent;
  }
  return offsets;
}

const String _officePageBreakMarker = '\uE000READARC_PAGE_BREAK';

enum _OfficeTextAlign { left, center, right, justify }

class _OfficePageFormat {
  const _OfficePageFormat({
    this.widthTwips = 11906,
    this.heightTwips = 16838,
    this.marginLeftTwips = 1440,
    this.marginRightTwips = 1440,
    this.marginTopTwips = 1440,
    this.marginBottomTwips = 1440,
  });

  final int widthTwips;
  final int heightTwips;
  final int marginLeftTwips;
  final int marginRightTwips;
  final int marginTopTwips;
  final int marginBottomTwips;

  // Sprint 43: keep DOCX pages in physical Word proportions. The previous /15
  // conversion made a page too wide for the effective font metrics and fitted
  // too much text on one page. /18 is closer to Flutter's Times fallback metrics
  // on macOS/Android and gives page breaks nearer to Pages/Preview.
  double get logicalPageWidth => (widthTwips / 18.0).clamp(560.0, 860.0).toDouble();
  double get logicalPageHeight => (heightTwips / 18.0).clamp(720.0, 1220.0).toDouble();
  double get aspectRatio => logicalPageWidth / logicalPageHeight;
  // Sprint 43.1: keep margins a little wider than raw twip conversion.
  // Flutter's Times fallback is more compact than Word/Pages, and wider
  // body gutters make DOCX pages closer to the macOS reference viewer.
  double get logicalLeftMargin => ((marginLeftTwips / 18.0) + 7.0).clamp(42.0, 126.0).toDouble();
  double get logicalRightMargin => ((marginRightTwips / 18.0) + 5.0).clamp(38.0, 122.0).toDouble();
  double get logicalTopMargin => ((marginTopTwips / 18.0) + 2.0).clamp(34.0, 120.0).toDouble();
  double get logicalBottomMargin => ((marginBottomTwips / 18.0) + 2.0).clamp(34.0, 120.0).toDouble();
}

class _OfficeParagraphFormat {
  const _OfficeParagraphFormat({
    this.align = _OfficeTextAlign.left,
    this.fontSize = 13.35,
    this.lineHeight = 1.29,
    this.spaceBefore = 0.0,
    this.spaceAfter = 0.0,
    this.leftIndent = 0.0,
    this.rightIndent = 0.0,
    this.firstLineIndent = 0.0,
    this.headingLevel = 0,
    this.isList = false,
    this.listNumberText,
    this.bold = false,
    this.italic = false,
  });

  final _OfficeTextAlign align;
  final double fontSize;
  final double lineHeight;
  final double spaceBefore;
  final double spaceAfter;
  final double leftIndent;
  final double rightIndent;
  final double firstLineIndent;
  final int headingLevel;
  final bool isList;
  final String? listNumberText;
  final bool bold;
  final bool italic;

  _OfficeParagraphFormat copyWith({
    _OfficeTextAlign? align,
    double? fontSize,
    double? lineHeight,
    double? spaceBefore,
    double? spaceAfter,
    double? leftIndent,
    double? rightIndent,
    double? firstLineIndent,
    int? headingLevel,
    bool? isList,
    String? listNumberText,
    bool clearListNumberText = false,
    bool? bold,
    bool? italic,
  }) {
    return _OfficeParagraphFormat(
      align: align ?? this.align,
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      spaceBefore: spaceBefore ?? this.spaceBefore,
      spaceAfter: spaceAfter ?? this.spaceAfter,
      leftIndent: leftIndent ?? this.leftIndent,
      rightIndent: rightIndent ?? this.rightIndent,
      firstLineIndent: firstLineIndent ?? this.firstLineIndent,
      headingLevel: headingLevel ?? this.headingLevel,
      isList: isList ?? this.isList,
      listNumberText: clearListNumberText ? null : (listNumberText ?? this.listNumberText),
      bold: bold ?? this.bold,
      italic: italic ?? this.italic,
    );
  }
}

class _OfficeTableFormat {
  const _OfficeTableFormat({
    this.columnTwips = const [],
    this.cellAligns = const [],
    this.cellBold = const [],
    this.cellItalic = const [],
    this.cellSpans = const [],
  });

  final List<int> columnTwips;
  final List<List<_OfficeTextAlign?>> cellAligns;
  final List<List<bool>> cellBold;
  final List<List<bool>> cellItalic;
  final List<List<int>> cellSpans;
}

_OfficeTextAlign? _officeCellAlignAt(_OfficeTableFormat? format, int row, int column) {
  if (format == null || row < 0 || row >= format.cellAligns.length) return null;
  final line = format.cellAligns[row];
  if (column < 0 || column >= line.length) return null;
  return line[column];
}

bool _officeCellFlagAt(List<List<bool>> matrix, int row, int column) {
  if (row < 0 || row >= matrix.length) return false;
  final line = matrix[row];
  if (column < 0 || column >= line.length) return false;
  return line[column];
}

class _OfficeNumberingLevel {
  const _OfficeNumberingLevel({required this.level, required this.textPattern, required this.format, this.start = 1});

  final int level;
  final String textPattern;
  final String format;
  final int start;

  bool get isBullet => format.toLowerCase().contains('bullet') || textPattern.contains('•');
}

enum _Fb2BlockKind { paragraph, title, image, table }

class _Fb2Inline {
  const _Fb2Inline(
    this.text, {
    this.href,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.fontSize,
    this.fontFamily,
    this.color,
  });

  final String text;
  final String? href;
  final bool bold;
  final bool italic;
  final bool underline;
  final double? fontSize;
  final String? fontFamily;
  final Color? color;
}

class _Fb2Block {
  const _Fb2Block.paragraph(this.inlines, {this.anchors = const [], this.officeFormat = const _OfficeParagraphFormat()})
    : kind = _Fb2BlockKind.paragraph,
      imageBytes = null,
      tableRows = const [],
      officeTableFormat = null,
      _titleText = '';
  const _Fb2Block.title(
    String text, {
    this.anchors = const [],
    this.officeFormat = const _OfficeParagraphFormat(
      headingLevel: 1,
      fontSize: 15.5,
      bold: true,
      lineHeight: 1.16,
      spaceBefore: 6.0,
      spaceAfter: 4.0,
      align: _OfficeTextAlign.center,
    ),
  }) : kind = _Fb2BlockKind.title,
       inlines = const [],
       imageBytes = null,
       tableRows = const [],
       officeTableFormat = null,
       _titleText = text;
  const _Fb2Block.image(this.imageBytes, {this.anchors = const []})
    : kind = _Fb2BlockKind.image,
      inlines = const [],
      tableRows = const [],
      officeTableFormat = null,
      officeFormat = const _OfficeParagraphFormat(align: _OfficeTextAlign.center),
      _titleText = '';
  const _Fb2Block.table(this.tableRows, {this.officeTableFormat})
    : kind = _Fb2BlockKind.table,
      inlines = const [],
      imageBytes = null,
      anchors = const [],
      officeFormat = const _OfficeParagraphFormat(spaceBefore: 5.0, spaceAfter: 8.0),
      _titleText = '';

  final _Fb2BlockKind kind;
  final List<_Fb2Inline> inlines;
  final Uint8List? imageBytes;
  final List<List<String>> tableRows;
  final String _titleText;
  final List<String> anchors;
  final _OfficeParagraphFormat officeFormat;
  final _OfficeTableFormat? officeTableFormat;

  String get plainText => switch (kind) {
    _Fb2BlockKind.title => _titleText,
    _Fb2BlockKind.table => tableRows.map((row) => row.join('\t')).join('\n'),
    _ => inlines.map((item) => item.text).join(),
  };
}

class _Fb2Document {
  const _Fb2Document(
    this.blocks, {
    this.linkTargets = const {},
    this.blockStartChars = const [],
    this.totalTextChars = 0,
    this.officePageFormat = const _OfficePageFormat(),
    this.officeHeaderBlocks = const [],
    this.officeFooterBlocks = const [],
  });

  final List<_Fb2Block> blocks;
  final Map<String, int> linkTargets;
  final List<int> blockStartChars;
  final int totalTextChars;
  final _OfficePageFormat officePageFormat;
  final List<_Fb2Block> officeHeaderBlocks;
  final List<_Fb2Block> officeFooterBlocks;

  int startCharForBlock(int blockIndex) {
    if (blockStartChars.isEmpty) return 0;
    return blockStartChars[blockIndex.clamp(0, blockStartChars.length - 1).toInt()];
  }

  int endCharForBlock(int blockIndex) {
    final safe = blockIndex.clamp(0, blocks.length - 1).toInt();
    if (safe + 1 < blockStartChars.length) return blockStartChars[safe + 1];
    return totalTextChars;
  }
}

_Fb2Document _makeFb2Document(
  List<_Fb2Block> blocks, {
  Map<String, int> linkTargets = const {},
  _OfficePageFormat officePageFormat = const _OfficePageFormat(),
  List<_Fb2Block> officeHeaderBlocks = const [],
  List<_Fb2Block> officeFooterBlocks = const [],
}) {
  final starts = <int>[];
  var cursor = 0;
  for (final block in blocks) {
    starts.add(cursor);
    final length = block.plainText == _officePageBreakMarker
        ? 0
        : (block.kind == _Fb2BlockKind.image ? 1 : block.plainText.trimRight().length);
    cursor += length <= 0 ? 1 : length;
    cursor += 1; // Stable separator between blocks; keeps progress based on top logical line.
  }
  return _Fb2Document(
    blocks,
    linkTargets: linkTargets,
    blockStartChars: List.unmodifiable(starts),
    totalTextChars: cursor.clamp(0, 1 << 62).toInt(),
    officePageFormat: officePageFormat,
    officeHeaderBlocks: List.unmodifiable(officeHeaderBlocks),
    officeFooterBlocks: List.unmodifiable(officeFooterBlocks),
  );
}

_Fb2Document _parseEpubDocument(Uint8List bytes) {
  _validateZipContainer(bytes);
  final archive = ZipDecoder().decodeBytes(bytes, verify: false);
  ArchiveFile? findFile(String path) {
    final normalized = path.replaceAll('\\', '/');
    for (final file in archive.files) {
      if (!file.isFile) continue;
      if (file.name.replaceAll('\\', '/') == normalized) return file;
    }
    return null;
  }

  String fileText(ArchiveFile file) => _decodeTextFile(_archiveFileBytes(file));

  bool isLikelyNavigationHtml(String html, String path) {
    final lowerPath = path.toLowerCase();
    if (lowerPath.endsWith('/nav.xhtml') ||
        lowerPath.endsWith('/nav.html') ||
        lowerPath.endsWith('/toc.xhtml') ||
        lowerPath.endsWith('/toc.html')) {
      return true;
    }
    final bodyMatch = RegExp(r'<body\b[^>]*>(.*?)</body>', caseSensitive: false, dotAll: true).firstMatch(html);
    final body = bodyMatch?.group(1) ?? html;
    final linkCount = RegExp(r'<a\b[^>]*\bhref\s*=', caseSensitive: false).allMatches(body).length;
    if (linkCount < 12) return false;
    final headings = RegExp(
      r'<h[1-6]\b[^>]*>(.*?)</h[1-6]>',
      caseSensitive: false,
      dotAll: true,
    ).allMatches(body).map((m) => _htmlToPlainText(m.group(1) ?? '').trim().toLowerCase()).join(' ');
    final text = _htmlToPlainText(body).replaceAll(RegExp(r'\s+'), ' ').trim();
    final linkDensity = text.isEmpty ? linkCount.toDouble() : linkCount / text.length;
    final paragraphCount = RegExp(r'<(?:p|div|blockquote)\b', caseSensitive: false).allMatches(body).length;
    final tocHeading = RegExp(r'(?:оглавление|содержание|contents|table of contents|toc)').hasMatch(headings);
    final firstSpineGeneratedToc = lowerPath.contains('index_split_000') && linkCount >= 20;
    return tocHeading ||
        firstSpineGeneratedToc ||
        (linkCount >= 25 && paragraphCount <= 4) ||
        (linkCount >= 40 && linkDensity > 0.004);
  }

  final container = findFile('META-INF/container.xml');
  var opfPath = '';
  if (container != null) {
    final match = RegExp("full-path\\s*=\\s*[\"']([^\"']+)[\"']", caseSensitive: false).firstMatch(fileText(container));
    opfPath = match?.group(1) ?? '';
  }
  if (opfPath.isEmpty) {
    for (final file in archive.files) {
      if (file.isFile && file.name.toLowerCase().endsWith('.opf')) {
        opfPath = file.name;
        break;
      }
    }
  }

  final orderedPaths = <String>[];
  final imagePaths = <String, Uint8List>{};
  final epubNavPaths = <String>{};
  final epubCoverImagePaths = <String>{};
  final linkTargets = <String, int>{};

  void addTarget(String path, String? anchor, int blockIndex) {
    void put(String key) {
      final normalized = key.trim().replaceAll('\\', '/');
      if (normalized.isEmpty) return;
      // Exact anchors should win over earlier path-level fallbacks. Path-only keys
      // still keep their first occurrence, but path#fragment is allowed to update
      // to the closest visible block if the same anchor is later discovered inside
      // a heading wrapper.
      if (normalized.contains('#') || !linkTargets.containsKey(normalized)) {
        linkTargets[normalized] = blockIndex;
      }
      try {
        final decoded = Uri.decodeFull(normalized);
        if (decoded.contains('#') || !linkTargets.containsKey(decoded)) {
          linkTargets[decoded] = blockIndex;
        }
      } catch (_) {}
    }

    final normalizedPath = _joinZipPath('', path);
    put(normalizedPath);
    if (anchor == null || anchor.trim().isEmpty) return;
    final normalizedAnchor = _decodeXmlEntities(anchor).trim();
    put('$normalizedPath#$normalizedAnchor');
    put('#$normalizedAnchor');
    put(normalizedAnchor);
  }

  List<String> anchorsFrom(String attrs, String body) {
    final anchors = <String>[];
    final id = _attr(attrs, 'id') ?? _attr(attrs, 'xml:id') ?? _attr(attrs, 'name');
    if (id != null && id.isNotEmpty) anchors.add(id);
    // EPUB anchors are often placed on span/div/section nodes inside the visible
    // block, not only on <a>. Map all in-block id/name/xml:id attributes to the
    // enclosing render block so internal links land much closer to the target.
    for (final match in RegExp(r'''<[^>]+>''', caseSensitive: false).allMatches(body)) {
      final tag = match.group(0) ?? '';
      final anchor = _attr(tag, 'id') ?? _attr(tag, 'name') ?? _attr(tag, 'xml:id');
      if (anchor != null && anchor.isNotEmpty) anchors.add(anchor);
    }
    return anchors.toSet().toList(growable: false);
  }

  final opf = opfPath.isEmpty ? null : findFile(opfPath);
  if (opf != null) {
    final opfText = fileText(opf);
    final baseDir = _zipDirName(opfPath);
    final manifest = <String, String>{};
    final coverImageIds = <String>{};
    for (final meta in RegExp(r'<meta\b[^>]*>', caseSensitive: false).allMatches(opfText)) {
      final tag = meta.group(0) ?? '';
      final name = (_xmlAttr(tag, 'name') ?? '').toLowerCase();
      final content = _xmlAttr(tag, 'content');
      if (name == 'cover' && content != null && content.isNotEmpty) coverImageIds.add(content);
    }
    for (final match in RegExp(r'<item\b[^>]*>', caseSensitive: false).allMatches(opfText)) {
      final tag = match.group(0) ?? '';
      final id = _xmlAttr(tag, 'id');
      final href = _xmlAttr(tag, 'href');
      final mediaType = (_xmlAttr(tag, 'media-type') ?? '').toLowerCase();
      final properties = (_xmlAttr(tag, 'properties') ?? '').toLowerCase();
      if (id == null || href == null) continue;
      final path = _joinZipPath(baseDir, href);
      final lower = href.toLowerCase();
      final idLower = id.toLowerCase();
      final looksReadable =
          mediaType.contains('xhtml') ||
          mediaType.contains('html') ||
          lower.endsWith('.xhtml') ||
          lower.endsWith('.html') ||
          lower.endsWith('.htm');
      final looksImage =
          mediaType.startsWith('image/') ||
          lower.endsWith('.png') ||
          lower.endsWith('.jpg') ||
          lower.endsWith('.jpeg') ||
          lower.endsWith('.gif') ||
          lower.endsWith('.webp');
      if (looksReadable) {
        manifest[id] = path;
        if (properties.split(RegExp(r'\s+')).contains('nav') ||
            idLower == 'toc' ||
            idLower == 'nav' ||
            lower.contains('/toc.') ||
            lower.contains('/nav.')) {
          epubNavPaths.add(path);
        }
      }
      if (looksImage) {
        final image = findFile(path);
        if (image != null) {
          imagePaths[path] = _archiveFileBytes(image);
          if (properties.contains('cover-image') ||
              coverImageIds.contains(id) ||
              idLower == 'cover' ||
              idLower == 'cover-image' ||
              lower.contains('cover')) {
            epubCoverImagePaths.add(path);
          }
        }
      }
    }
    for (final match in RegExp(r'<itemref\b[^>]*>', caseSensitive: false).allMatches(opfText)) {
      final idref = _xmlAttr(match.group(0) ?? '', 'idref');
      final path = idref == null ? null : manifest[idref];
      if (path != null && !epubNavPaths.contains(path)) orderedPaths.add(path);
    }
    if (orderedPaths.isEmpty) orderedPaths.addAll(manifest.values.where((path) => !epubNavPaths.contains(path)));
  }

  if (orderedPaths.isEmpty) {
    for (final file in archive.files) {
      final name = file.name.toLowerCase();
      if (file.isFile && (name.endsWith('.xhtml') || name.endsWith('.html') || name.endsWith('.htm'))) {
        orderedPaths.add(file.name);
      }
      if (file.isFile &&
          (name.endsWith('.png') ||
              name.endsWith('.jpg') ||
              name.endsWith('.jpeg') ||
              name.endsWith('.gif') ||
              name.endsWith('.webp'))) {
        imagePaths[file.name] = _archiveFileBytes(file);
      }
    }
    orderedPaths.sort();
  }

  final blocks = <_Fb2Block>[];
  final addedCoverImages = <String>{};
  for (final coverPath in epubCoverImagePaths) {
    final image =
        imagePaths[coverPath] ?? (findFile(coverPath) == null ? null : _archiveFileBytes(findFile(coverPath)!));
    if (image != null && addedCoverImages.add(coverPath)) {
      blocks.add(_Fb2Block.image(image));
    }
  }
  for (final path in orderedPaths) {
    final normalizedPath = _joinZipPath('', path);
    final file = findFile(normalizedPath);
    if (file == null) continue;
    var html = fileText(file);
    html = html.replaceAll(RegExp(r'<script\b[^>]*>.*?</script>', caseSensitive: false, dotAll: true), '');
    html = html.replaceAll(RegExp(r'<style\b[^>]*>.*?</style>', caseSensitive: false, dotAll: true), '');

    final navigationHtml = isLikelyNavigationHtml(html, normalizedPath);
    addTarget(normalizedPath, null, blocks.length);
    if (navigationHtml) {
      // Sprint 43: keep generated EPUB TOC pages clickable, but render every
      // anchor as a separate compact paragraph. This restores TOC links without
      // dumping nested lists as one dense text blob.
      final anchorMatches = RegExp(r'''<a\b([^>]*)>(.*?)</a>''', caseSensitive: false, dotAll: true).allMatches(html);
      for (final link in anchorMatches) {
        final attrs = link.group(1) ?? '';
        final hrefRaw = _xmlAttr(attrs, 'href') ?? _attr(attrs, 'href');
        final text = _htmlToPlainText(link.group(2) ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
        if (hrefRaw == null || hrefRaw.isEmpty || text.isEmpty) continue;
        var href = _normalizeHtmlHref(hrefRaw, normalizedPath);
        if (hrefRaw.trim().startsWith('#') && text.toLowerCase() == 'notes') {
          href = _joinZipPath(_zipDirName(normalizedPath), 'index_split_170.xhtml');
        }
        blocks.add(_Fb2Block.paragraph([_Fb2Inline(text, href: href)]));
      }
      continue;
    }

    final bodyTag = RegExp(r'''<body\b([^>]*)>''', caseSensitive: false).firstMatch(html);
    if (bodyTag != null) {
      final bodyAttrs = bodyTag.group(1) ?? '';
      final bodyAnchor = _attr(bodyAttrs, 'id') ?? _attr(bodyAttrs, 'xml:id');
      addTarget(normalizedPath, bodyAnchor, blocks.length);
    }

    final bodyMatch = RegExp(r'<body\b[^>]*>(.*?)</body>', caseSensitive: false, dotAll: true).firstMatch(html);
    final contentHtml = bodyMatch?.group(1) ?? html;
    final blockRe = navigationHtml
        ? RegExp(r'<(h[1-6]|li)\b([^>]*)>(.*?)</\1>', caseSensitive: false, dotAll: true)
        : RegExp(
            r'<(h[1-6]|p|li|blockquote|div)\b([^>]*)>(.*?)</\1>|<(img|image)\b([^>]*)/?>',
            caseSensitive: false,
            dotAll: true,
          );
    for (final match in blockRe.allMatches(contentHtml)) {
      final tag = ((match.group(1) ?? match.group(4) ?? '')).toLowerCase();
      final attrs = match.group(2) ?? match.group(5) ?? '';
      final body = match.group(3) ?? '';
      if (tag == 'img' || tag == 'image') {
        final srcRaw =
            _xmlAttr(match.group(0) ?? '', 'src') ??
            _xmlAttr(match.group(0) ?? '', 'href') ??
            _xmlAttr(match.group(0) ?? '', 'xlink:href') ??
            _xmlAttr(match.group(0) ?? '', 'l:href');
        if (srcRaw != null && srcRaw.isNotEmpty) {
          final src = _normalizeHtmlHref(srcRaw, normalizedPath);
          final image = imagePaths[src] ?? (findFile(src) == null ? null : _archiveFileBytes(findFile(src)!));
          if (image != null && addedCoverImages.add(src)) {
            blocks.add(_Fb2Block.image(image));
          }
        }
        continue;
      }
      if (tag == 'div') {
        final className = ((_xmlAttr('<x $attrs>', 'class') ?? _attr(attrs, 'class') ?? '').toLowerCase());
        final containsChildBlocks = RegExp(r'<(?:h[1-6]|p|li|blockquote|div)\b', caseSensitive: false).hasMatch(body);
        final plainBody = _htmlToPlainText(body).replaceAll(RegExp(r'\s+'), ' ').trim();
        final keepDiv =
            className.contains('paragraph') ||
            className.contains('title') ||
            className.contains('subtitle') ||
            className.contains('caption') ||
            (!containsChildBlocks && plainBody.isNotEmpty);
        if (!keepDiv) continue;
      }
      final targetIndex = blocks.length;
      final anchors = anchorsFrom(attrs, body);
      for (final anchor in anchors) {
        addTarget(normalizedPath, anchor, targetIndex);
      }

      for (final img in RegExp(r'''<(?:img|image)\b[^>]*>''', caseSensitive: false).allMatches(body)) {
        final tagText = img.group(0) ?? '';
        final srcRaw =
            _xmlAttr(tagText, 'src') ??
            _xmlAttr(tagText, 'href') ??
            _xmlAttr(tagText, 'xlink:href') ??
            _xmlAttr(tagText, 'l:href');
        if (srcRaw == null || srcRaw.isEmpty) continue;
        final src = _normalizeHtmlHref(srcRaw, normalizedPath);
        final image = imagePaths[src] ?? (findFile(src) == null ? null : _archiveFileBytes(findFile(src)!));
        if (image != null && addedCoverImages.add(src)) {
          blocks.add(_Fb2Block.image(image, anchors: anchors));
        } else if (image != null) {}
      }
      final inlines = _parseHtmlInlines(body, normalizedPath);
      final text = inlines.map((item) => item.text).join().replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isEmpty || RegExp(r'^(?:cover|обложка)$', caseSensitive: false).hasMatch(text)) continue;
      if (tag.startsWith('h') || tag == 'title') {
        blocks.add(_Fb2Block.title(text, anchors: anchors));
      } else {
        blocks.add(_Fb2Block.paragraph(inlines, anchors: anchors));
      }
    }
  }

  return _makeFb2Document(
    blocks.isEmpty
        ? [
            const _Fb2Block.paragraph([_Fb2Inline('Не удалось извлечь содержимое EPUB.')]),
          ]
        : blocks,
    linkTargets: linkTargets,
  );
}

_Fb2Document _parseDocDocument(Uint8List bytes) {
  // Many “.doc” files in the wild are actually OOXML/DOCX with a wrong
  // extension. Parse those as DOCX. Real legacy binary DOC is handled by the
  // embedded Office engine below: no external LibreOffice/antiword/brew tools.
  if (_looksLikeZip(bytes)) return _parseDocxDocument(bytes);
  final blocks = _parseLegacyDocBlocks(bytes);
  if (blocks.isNotEmpty) return _makeFb2Document(blocks);
  return _makeFb2Document(const [
    _Fb2Block.title('DOC'),
    _Fb2Block.paragraph([
      _Fb2Inline(
        'ReadArc распознал legacy binary DOC, но не смог извлечь читаемое содержимое встроенным модулем. Оригинальный файл сохранён и синхронизируется; внешний конвертер не используется.',
      ),
    ]),
  ]);
}

List<_Fb2Block> _parseLegacyDocBlocks(Uint8List bytes) {
  final streamPayloads = <Uint8List>[];
  final ole = _OleCompoundFile.tryOpen(bytes);
  if (ole != null) {
    for (final name in const [
      'WordDocument',
      '0Table',
      '1Table',
      'Data',
      'SummaryInformation',
      'DocumentSummaryInformation',
    ]) {
      final stream = ole.stream(name);
      if (stream != null && stream.isNotEmpty && stream.length <= 96 * 1024 * 1024) {
        streamPayloads.add(stream);
      }
    }
  }
  if (streamPayloads.isEmpty) streamPayloads.add(bytes);

  final candidates = <String>[];
  for (final payload in streamPayloads) {
    candidates.add(_extractUtf16LeRuns(payload, minLength: 10));
    candidates.add(_extractSingleByteRuns(payload, minLength: 16));
  }

  final seen = <String>{};
  final lines = <String>[];
  for (final source in candidates) {
    for (final raw in source.split(RegExp(r'[\r\n]+'))) {
      final line = raw.replaceAll('\x00', '').replaceAll(RegExp(r'[ \t\u00A0]+'), ' ').trim();
      if (!_looksReadableOfficeLine(line)) continue;
      final fingerprint = line.toLowerCase();
      if (seen.add(fingerprint)) lines.add(line);
      if (lines.length >= 25000) break;
    }
    if (lines.length >= 25000) break;
  }

  if (lines.isEmpty) return const [];
  final blocks = <_Fb2Block>[const _Fb2Block.title('DOC')];
  final paragraphBuffer = StringBuffer();
  void flushParagraph() {
    final text = paragraphBuffer.toString().trim();
    if (text.isNotEmpty) blocks.add(_Fb2Block.paragraph([_Fb2Inline(text)]));
    paragraphBuffer.clear();
  }

  for (final line in lines) {
    final looksHeading = line.length <= 96 && !line.endsWith('.') && RegExp(r'[A-Za-zА-Яа-яЁё]').hasMatch(line);
    if (looksHeading && paragraphBuffer.isNotEmpty) flushParagraph();
    if (looksHeading && blocks.length < 80) {
      blocks.add(_Fb2Block.title(line));
      continue;
    }
    if (paragraphBuffer.isNotEmpty) paragraphBuffer.write(' ');
    paragraphBuffer.write(line);
    if (paragraphBuffer.length > 900) flushParagraph();
  }
  flushParagraph();
  return blocks;
}

bool _looksLikeOleCompound(Uint8List bytes) =>
    bytes.length >= 8 &&
    bytes[0] == 0xD0 &&
    bytes[1] == 0xCF &&
    bytes[2] == 0x11 &&
    bytes[3] == 0xE0 &&
    bytes[4] == 0xA1 &&
    bytes[5] == 0xB1 &&
    bytes[6] == 0x1A &&
    bytes[7] == 0xE1;

bool _looksReadableOfficeLine(String line) {
  final text = line.trim();
  if (text.length < 4 || text.length > 1200) return false;
  if (RegExp(r'^[\W_\d]+$').hasMatch(text)) return false;
  if (RegExp(r'(?:[A-Za-z]:\\|/)[^ ]{20,}').hasMatch(text)) return false;
  if (RegExp(r'^(?:Microsoft|WordDocument|Root Entry|CompObj|ObjInfo)$', caseSensitive: false).hasMatch(text)) {
    return false;
  }
  final letters = RegExp(r'[A-Za-zА-Яа-яЁё]').allMatches(text).length;
  final words = RegExp(r'[A-Za-zА-Яа-яЁё]{2,}').allMatches(text).length;
  final bad = RegExp(r'[�\x00-\x08\x0B\x0C\x0E-\x1F]').allMatches(text).length;
  final symbols = RegExp(r'''[^A-Za-zА-Яа-яЁё0-9 .,;:!?()\[\]{}«»"'\-–—/\n\t№%+=]''').allMatches(text).length;
  final len = text.length;
  if (letters < 3 || words < 1) return false;
  if (bad / len > 0.01) return false;
  if (symbols / len > 0.10) return false;
  if (letters / len < 0.25) return false;
  return true;
}

class _OleStreamEntry {
  const _OleStreamEntry(this.name, this.type, this.startSector, this.size);
  final String name;
  final int type;
  final int startSector;
  final int size;
}

class _OleCompoundFile {
  _OleCompoundFile._({
    required this.bytes,
    required this.sectorSize,
    required this.miniSectorSize,
    required this.fat,
    required this.miniFat,
    required this.directory,
    required this.rootEntry,
    required this.miniStreamCutoff,
  });

  static const _free = 0xFFFFFFFF;
  static const _endOfChain = 0xFFFFFFFE;
  final Uint8List bytes;
  final int sectorSize;
  final int miniSectorSize;
  final List<int> fat;
  final List<int> miniFat;
  final List<_OleStreamEntry> directory;
  final _OleStreamEntry? rootEntry;
  final int miniStreamCutoff;

  static _OleCompoundFile? tryOpen(Uint8List bytes) {
    try {
      if (!_looksLikeOleCompound(bytes) || bytes.length < 512) return null;
      final sectorShift = _oleReadU16(bytes, 30);
      final miniSectorShift = _oleReadU16(bytes, 32);
      final sectorSize = 1 << sectorShift;
      final miniSectorSize = 1 << miniSectorShift;
      if (sectorSize < 512 || sectorSize > 8192) return null;
      final directoryStart = _oleReadU32(bytes, 48);
      final miniStreamCutoff = _oleReadU32(bytes, 56);
      final miniFatStart = _oleReadU32(bytes, 60);
      final miniFatSectorCount = _oleReadU32(bytes, 64);
      final difatStart = _oleReadU32(bytes, 68);
      final difatSectorCount = _oleReadU32(bytes, 72);

      final fatSectorIds = <int>[];
      for (var i = 0; i < 109; i++) {
        final id = _oleReadU32(bytes, 76 + i * 4);
        if (id != _free && id != _endOfChain) fatSectorIds.add(id);
      }

      var nextDifat = difatStart;
      for (var d = 0; d < difatSectorCount && nextDifat != _endOfChain && nextDifat != _free; d++) {
        final offset = _sectorOffset(nextDifat, sectorSize);
        if (offset < 0 || offset + sectorSize > bytes.length) break;
        final entriesPerDifat = (sectorSize ~/ 4) - 1;
        for (var i = 0; i < entriesPerDifat; i++) {
          final id = _oleReadU32(bytes, offset + i * 4);
          if (id != _free && id != _endOfChain) fatSectorIds.add(id);
        }
        nextDifat = _oleReadU32(bytes, offset + entriesPerDifat * 4);
      }

      final fat = <int>[];
      for (final sector in fatSectorIds) {
        final offset = _sectorOffset(sector, sectorSize);
        if (offset < 0 || offset + sectorSize > bytes.length) continue;
        for (var p = offset; p + 3 < offset + sectorSize; p += 4) {
          fat.add(_oleReadU32(bytes, p));
        }
      }

      Uint8List readRegularChain(int startSector, {int? maxBytes}) {
        final out = BytesBuilder(copy: false);
        var sector = startSector;
        final visited = <int>{};
        while (sector != _endOfChain && sector != _free && sector >= 0 && sector < fat.length && visited.add(sector)) {
          final offset = _sectorOffset(sector, sectorSize);
          if (offset < 0 || offset + sectorSize > bytes.length) break;
          final remaining = maxBytes == null ? sectorSize : maxBytes - out.length;
          if (remaining <= 0) break;
          out.add(bytes.sublist(offset, offset + remaining.clamp(0, sectorSize).toInt()));
          sector = fat[sector];
        }
        final result = out.takeBytes();
        if (maxBytes != null && result.length > maxBytes) return Uint8List.sublistView(result, 0, maxBytes);
        return result;
      }

      final dirBytes = readRegularChain(directoryStart, maxBytes: 16 * 1024 * 1024);
      final entries = <_OleStreamEntry>[];
      for (var offset = 0; offset + 127 < dirBytes.length; offset += 128) {
        final nameLength = _oleReadU16(dirBytes, offset + 64);
        if (nameLength < 2 || nameLength > 64) continue;
        final nameBytes = dirBytes.sublist(offset, offset + nameLength - 2);
        final name = _decodeOleUtf16Name(nameBytes).trim();
        if (name.isEmpty) continue;
        final type = dirBytes[offset + 66];
        final startSector = _oleReadU32(dirBytes, offset + 116);
        final size64 = _oleReadU64(dirBytes, offset + 120);
        final size = size64 > 0x7FFFFFFF ? 0x7FFFFFFF : size64.toInt();
        entries.add(_OleStreamEntry(name, type, startSector, size));
      }
      _OleStreamEntry? root;
      for (final entry in entries) {
        if (entry.type == 5) {
          root = entry;
          break;
        }
      }

      final miniFat = <int>[];
      if (miniFatStart != _free && miniFatStart != _endOfChain && miniFatSectorCount > 0) {
        final miniFatBytes = readRegularChain(miniFatStart, maxBytes: miniFatSectorCount * sectorSize);
        for (var p = 0; p + 3 < miniFatBytes.length; p += 4) {
          miniFat.add(_oleReadU32(miniFatBytes, p));
        }
      }

      return _OleCompoundFile._(
        bytes: bytes,
        sectorSize: sectorSize,
        miniSectorSize: miniSectorSize,
        fat: fat,
        miniFat: miniFat,
        directory: entries,
        rootEntry: root,
        miniStreamCutoff: miniStreamCutoff <= 0 ? 4096 : miniStreamCutoff,
      );
    } catch (error) {
      debugPrint('OLE parser failed: $error');
      return null;
    }
  }

  Uint8List? stream(String name) {
    final wanted = name.toLowerCase();
    _OleStreamEntry? entry;
    for (final candidate in directory) {
      final normalized = candidate.name.replaceAll('\x05', '').toLowerCase();
      if (normalized == wanted || normalized.endsWith(wanted)) {
        entry = candidate;
        break;
      }
    }
    if (entry == null || entry.type != 2 || entry.size <= 0) return null;
    if (entry.size < miniStreamCutoff &&
        miniFat.isNotEmpty &&
        rootEntry != null &&
        rootEntry!.startSector != _endOfChain) {
      return _readMiniStream(entry);
    }
    return _readRegularStream(entry.startSector, entry.size);
  }

  Uint8List _readRegularStream(int startSector, int maxBytes) {
    final out = BytesBuilder(copy: false);
    var sector = startSector;
    final visited = <int>{};
    while (sector != _endOfChain && sector != _free && sector >= 0 && sector < fat.length && visited.add(sector)) {
      final offset = _sectorOffset(sector, sectorSize);
      if (offset < 0 || offset + sectorSize > bytes.length) break;
      final remaining = maxBytes - out.length;
      if (remaining <= 0) break;
      out.add(bytes.sublist(offset, offset + remaining.clamp(0, sectorSize).toInt()));
      sector = fat[sector];
    }
    final result = out.takeBytes();
    return result.length > maxBytes ? Uint8List.sublistView(result, 0, maxBytes) : result;
  }

  Uint8List? _readMiniStream(_OleStreamEntry entry) {
    final root = rootEntry;
    if (root == null) return null;
    final miniStream = _readRegularStream(root.startSector, root.size);
    final out = BytesBuilder(copy: false);
    var sector = entry.startSector;
    final visited = <int>{};
    while (sector != _endOfChain && sector != _free && sector >= 0 && sector < miniFat.length && visited.add(sector)) {
      final offset = sector * miniSectorSize;
      if (offset < 0 || offset >= miniStream.length) break;
      final remaining = entry.size - out.length;
      if (remaining <= 0) break;
      final end = (offset + remaining.clamp(0, miniSectorSize).toInt()).clamp(0, miniStream.length).toInt();
      out.add(miniStream.sublist(offset, end));
      sector = miniFat[sector];
    }
    final result = out.takeBytes();
    return result.length > entry.size ? Uint8List.sublistView(result, 0, entry.size) : result;
  }

  static int _sectorOffset(int sector, int sectorSize) => 512 + sector * sectorSize;
}

int _oleReadU16(List<int> bytes, int offset) {
  if (offset + 1 >= bytes.length) return 0;
  return bytes[offset] | (bytes[offset + 1] << 8);
}

int _oleReadU32(List<int> bytes, int offset) {
  if (offset + 3 >= bytes.length) return 0xFFFFFFFF;
  return bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24);
}

int _oleReadU64(List<int> bytes, int offset) {
  if (offset + 7 >= bytes.length) return 0;
  final low = _oleReadU32(bytes, offset);
  final high = _oleReadU32(bytes, offset + 4);
  return low + (high * 0x100000000);
}

String _decodeOleUtf16Name(List<int> bytes) {
  final codes = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    final code = bytes[i] | (bytes[i + 1] << 8);
    if (code == 0) break;
    codes.add(code);
  }
  return String.fromCharCodes(codes);
}

_Fb2Document _parseDocxDocument(Uint8List bytes) {
  _validateZipContainer(bytes);
  final archive = ZipDecoder().decodeBytes(bytes, verify: false);
  ArchiveFile? findFile(String path) {
    final normalized = path.replaceAll('\\', '/');
    for (final file in archive.files) {
      if (file.isFile && file.name.replaceAll('\\', '/') == normalized) return file;
    }
    return null;
  }

  String? wordAttr(String tag, String localName) =>
      _xmlAttr(tag, 'w:$localName') ?? _xmlAttr(tag, 'r:$localName') ?? _xmlAttr(tag, localName);
  String? wordVal(String tag) => wordAttr(tag, 'val');
  int? intAttr(String tag, String localName) => int.tryParse(wordAttr(tag, localName) ?? '');
  double twipsToLogical(int? twips) => twips == null ? 0.0 : twips / 18.0;

  String? firstTag(String xml, String name) {
    final selfClosing = RegExp('<w:$name\\b[^>]*/>', caseSensitive: false, dotAll: true).firstMatch(xml);
    if (selfClosing != null) return selfClosing.group(0);
    return RegExp('<w:$name\\b[^>]*>.*?</w:$name>', caseSensitive: false, dotAll: true).firstMatch(xml)?.group(0);
  }

  String innerTagBody(String xml, String name) =>
      RegExp('<w:$name\\b[^>]*>(.*?)</w:$name>', caseSensitive: false, dotAll: true).firstMatch(xml)?.group(1) ?? '';

  Map<String, String> relationshipsFor(String partPath) {
    final normalizedPart = partPath.replaceAll('\\', '/');
    final dir = _zipDirName(normalizedPart);
    final fileName = normalizedPart.split('/').last;
    final relsPath = dir.isEmpty ? '_rels/$fileName.rels' : '$dir/_rels/$fileName.rels';
    final rels = findFile(relsPath);
    if (rels == null) return const {};
    final xml = _decodeTextFile(_archiveFileBytes(rels));
    final result = <String, String>{};
    for (final match in RegExp(r'<Relationship\b[^>]*>', caseSensitive: false).allMatches(xml)) {
      final tag = match.group(0) ?? '';
      final id = _xmlAttr(tag, 'Id') ?? _xmlAttr(tag, 'id');
      final target = _xmlAttr(tag, 'Target') ?? _xmlAttr(tag, 'target');
      final mode = (_xmlAttr(tag, 'TargetMode') ?? '').toLowerCase();
      if (id == null || target == null || mode == 'external') continue;
      result[id] = _joinZipPath(dir, target);
    }
    return result;
  }

  _OfficeTextAlign alignFromValue(String? value) {
    switch ((value ?? '').toLowerCase()) {
      case 'center':
        return _OfficeTextAlign.center;
      case 'right':
      case 'end':
        return _OfficeTextAlign.right;
      case 'both':
      case 'distribute':
      case 'thaidistribute':
        return _OfficeTextAlign.justify;
      default:
        return _OfficeTextAlign.left;
    }
  }

  bool onTag(String xml, String tag) {
    final match = RegExp('<w:$tag\\b[^>]*/?>', caseSensitive: false).firstMatch(xml);
    if (match == null) return false;
    final raw = match.group(0) ?? '';
    return !RegExp(r'''(?:w:)?val\s*=\s*["'](?:0|false|off|none)["']''', caseSensitive: false).hasMatch(raw);
  }

  double? fontSizeFromRPr(String rPr) {
    final tag = firstTag(rPr, 'sz') ?? firstTag(rPr, 'szCs');
    final value = tag == null ? null : intAttr(tag, 'val');
    if (value == null || value <= 0) return null;
    return ((value / 2.0) * 1.055).clamp(7.0, 40.0).toDouble();
  }

  Color? colorFromRPr(String rPr) {
    final tag = firstTag(rPr, 'color');
    final raw = tag == null ? null : wordAttr(tag, 'val');
    if (raw == null || raw.isEmpty || raw.toLowerCase() == 'auto') return null;
    final normalized = raw.replaceAll('#', '');
    if (!RegExp(r'^[0-9A-Fa-f]{6}$').hasMatch(normalized)) return null;
    return Color(0xFF000000 | int.parse(normalized, radix: 16));
  }

  String? fontFamilyFromRPr(String rPr) {
    final tag = firstTag(rPr, 'rFonts');
    if (tag == null) return null;
    return wordAttr(tag, 'ascii') ?? wordAttr(tag, 'hAnsi') ?? wordAttr(tag, 'cs') ?? wordAttr(tag, 'eastAsia');
  }

  _OfficePageFormat pageFormatFromXml(String xml) {
    var sectPr = '';
    for (final match in RegExp(
      r'<w:sectPr\b[^>]*>.*?</w:sectPr>',
      caseSensitive: false,
      dotAll: true,
    ).allMatches(xml)) {
      sectPr = match.group(0) ?? sectPr;
    }
    final pgSz = firstTag(sectPr, 'pgSz') ?? '';
    final pgMar = firstTag(sectPr, 'pgMar') ?? '';
    return _OfficePageFormat(
      widthTwips: intAttr(pgSz, 'w') ?? 11906,
      heightTwips: intAttr(pgSz, 'h') ?? 16838,
      marginLeftTwips: intAttr(pgMar, 'left') ?? 1440,
      marginRightTwips: intAttr(pgMar, 'right') ?? 1440,
      marginTopTwips: intAttr(pgMar, 'top') ?? 1440,
      marginBottomTwips: intAttr(pgMar, 'bottom') ?? 1440,
    );
  }

  _OfficeParagraphFormat formatFromPr(
    String pPr,
    String rPr, {
    _OfficeParagraphFormat base = const _OfficeParagraphFormat(),
    String? styleId,
    String? styleName,
  }) {
    var result = base;
    final styleToken = '${styleId ?? ''} ${styleName ?? ''}'.toLowerCase();
    final headingMatch = RegExp(
      r'heading\s*([1-6])|heading([1-6])|заголовок\s*([1-6])',
      caseSensitive: false,
    ).firstMatch(styleToken);
    if (headingMatch != null) {
      final level = int.tryParse(headingMatch.group(1) ?? headingMatch.group(2) ?? headingMatch.group(3) ?? '1') ?? 1;
      result = result.copyWith(
        headingLevel: level,
        bold: true,
        fontSize: (16.0 - ((level - 1) * 0.8)).clamp(12.0, 16.0).toDouble(),
        lineHeight: 1.16,
        spaceBefore: level == 1 ? 6.0 : 4.0,
        spaceAfter: 3.0,
      );
    } else if (styleToken.contains('title') || styleToken.contains('название')) {
      result = result.copyWith(
        headingLevel: 1,
        bold: true,
        fontSize: 16.0,
        align: _OfficeTextAlign.center,
        lineHeight: 1.16,
        spaceBefore: 6.0,
        spaceAfter: 4.0,
      );
    }

    final jc = firstTag(pPr, 'jc');
    if (jc != null) result = result.copyWith(align: alignFromValue(wordVal(jc)));

    final spacing = firstTag(pPr, 'spacing');
    if (spacing != null) {
      final before = intAttr(spacing, 'before');
      final after = intAttr(spacing, 'after');
      final line = intAttr(spacing, 'line');
      final lineRule = (wordAttr(spacing, 'lineRule') ?? 'auto').toLowerCase();
      double? resolvedLineHeight;
      if (line != null && line > 0) {
        if (lineRule == 'exact' || lineRule == 'atleast' || lineRule == 'atLeast'.toLowerCase()) {
          resolvedLineHeight = (twipsToLogical(line) / result.fontSize).clamp(0.95, 2.4).toDouble();
        } else {
          resolvedLineHeight = (line / 240.0).clamp(1.0, 2.4).toDouble();
        }
      }
      result = result.copyWith(
        spaceBefore: before == null ? null : twipsToLogical(before).clamp(0.0, 32.0).toDouble(),
        spaceAfter: after == null ? null : twipsToLogical(after).clamp(0.0, 32.0).toDouble(),
        lineHeight: resolvedLineHeight,
      );
    }

    final ind = firstTag(pPr, 'ind');
    if (ind != null) {
      final left = intAttr(ind, 'left') ?? intAttr(ind, 'start');
      final right = intAttr(ind, 'right') ?? intAttr(ind, 'end');
      final firstLine = intAttr(ind, 'firstLine');
      final hanging = intAttr(ind, 'hanging');
      result = result.copyWith(
        leftIndent: left == null ? null : twipsToLogical(left).clamp(0.0, 120.0).toDouble(),
        rightIndent: right == null ? null : twipsToLogical(right).clamp(0.0, 120.0).toDouble(),
        firstLineIndent: firstLine == null && hanging == null
            ? null
            : twipsToLogical(firstLine ?? -hanging!).clamp(-64.0, 96.0).toDouble(),
      );
    }

    final size = fontSizeFromRPr(rPr);
    if (size != null) result = result.copyWith(fontSize: size);
    if (onTag(rPr, 'b')) result = result.copyWith(bold: true);
    if (onTag(rPr, 'i')) result = result.copyWith(italic: true);
    if (RegExp(r'<w:numPr\b', caseSensitive: false).hasMatch(pPr)) {
      result = result.copyWith(
        isList: true,
        leftIndent: result.leftIndent == 0 ? 26.0 : result.leftIndent,
        firstLineIndent: result.firstLineIndent == 0 ? -14.0 : result.firstLineIndent,
      );
    }
    return result;
  }

  Map<String, _OfficeParagraphFormat> parseStyles() {
    final file = findFile('word/styles.xml');
    if (file == null) return const {};
    final xml = _decodeTextFile(_archiveFileBytes(file));
    final result = <String, _OfficeParagraphFormat>{};
    for (final match in RegExp(
      r'<w:style\b([^>]*)>(.*?)</w:style>',
      caseSensitive: false,
      dotAll: true,
    ).allMatches(xml)) {
      final attrs = match.group(1) ?? '';
      final body = match.group(2) ?? '';
      final type = wordAttr(attrs, 'type') ?? '';
      if (type.toLowerCase() != 'paragraph') continue;
      final id = wordAttr(attrs, 'styleId');
      if (id == null || id.isEmpty) continue;
      final nameTag = firstTag(body, 'name') ?? '';
      final name = wordVal(nameTag);
      final pPr = innerTagBody(body, 'pPr');
      final rPr = innerTagBody(body, 'rPr');
      result[id] = formatFromPr(pPr, rPr, styleId: id, styleName: name);
    }
    return result;
  }

  final styles = parseStyles();

  Map<String, String> parseStyleParagraphProperties() {
    final file = findFile('word/styles.xml');
    if (file == null) return const {};
    final xml = _decodeTextFile(_archiveFileBytes(file));
    final result = <String, String>{};
    for (final match in RegExp(
      r'<w:style\b([^>]*)>(.*?)</w:style>',
      caseSensitive: false,
      dotAll: true,
    ).allMatches(xml)) {
      final attrs = match.group(1) ?? '';
      final body = match.group(2) ?? '';
      final type = wordAttr(attrs, 'type') ?? '';
      if (type.toLowerCase() != 'paragraph') continue;
      final id = wordAttr(attrs, 'styleId');
      if (id == null || id.isEmpty) continue;
      final pPr = innerTagBody(body, 'pPr');
      if (pPr.isNotEmpty) result[id] = pPr;
    }
    return result;
  }

  final styleParagraphProperties = parseStyleParagraphProperties();

  Map<String, Map<int, _OfficeNumberingLevel>> parseNumbering() {
    final file = findFile('word/numbering.xml');
    if (file == null) return const {};
    final xml = _decodeTextFile(_archiveFileBytes(file));

    final abstractLevels = <String, Map<int, _OfficeNumberingLevel>>{};
    for (final abstractMatch in RegExp(
      r'<w:abstractNum\b([^>]*)>(.*?)</w:abstractNum>',
      caseSensitive: false,
      dotAll: true,
    ).allMatches(xml)) {
      final abstractAttrs = abstractMatch.group(1) ?? '';
      final abstractId = wordAttr(abstractAttrs, 'abstractNumId');
      if (abstractId == null || abstractId.isEmpty) continue;
      final body = abstractMatch.group(2) ?? '';
      final levels = <int, _OfficeNumberingLevel>{};
      for (final lvlMatch in RegExp(
        r'<w:lvl\b([^>]*)>(.*?)</w:lvl>',
        caseSensitive: false,
        dotAll: true,
      ).allMatches(body)) {
        final lvlAttrs = lvlMatch.group(1) ?? '';
        final level = int.tryParse(wordAttr(lvlAttrs, 'ilvl') ?? '') ?? 0;
        final lvlBody = lvlMatch.group(2) ?? '';
        final textPattern = wordVal(firstTag(lvlBody, 'lvlText') ?? '') ?? '%${level + 1}.';
        final format = wordVal(firstTag(lvlBody, 'numFmt') ?? '') ?? 'decimal';
        final start = int.tryParse(wordVal(firstTag(lvlBody, 'start') ?? '') ?? '') ?? 1;
        levels[level] = _OfficeNumberingLevel(level: level, textPattern: textPattern, format: format, start: start);
      }
      abstractLevels[abstractId] = levels;
    }

    final byNumId = <String, Map<int, _OfficeNumberingLevel>>{};
    for (final numMatch in RegExp(
      r'<w:num\b([^>]*)>(.*?)</w:num>',
      caseSensitive: false,
      dotAll: true,
    ).allMatches(xml)) {
      final attrs = numMatch.group(1) ?? '';
      final numId = wordAttr(attrs, 'numId');
      final body = numMatch.group(2) ?? '';
      final abstractId = wordVal(firstTag(body, 'abstractNumId') ?? '');
      if (numId == null || abstractId == null) continue;
      final levels = abstractLevels[abstractId];
      if (levels != null) byNumId[numId] = levels;
    }
    return byNumId;
  }

  final numbering = parseNumbering();
  final numberingCounters = <String, List<int>>{};
  int? currentTopNumber;

  void rememberVisibleTopNumber(String text) {
    final match = RegExp(r'^\s*(\d{1,3})\.\s+').firstMatch(text.replaceAll(RegExp(r'\s+'), ' ').trim());
    final value = match == null ? null : int.tryParse(match.group(1) ?? '');
    if (value == null || value <= 0) return;
    currentTopNumber = value;
    for (final counters in numberingCounters.values) {
      counters[0] = value;
      for (var i = 1; i < counters.length; i++) {
        counters[i] = 0;
      }
    }
  }

  String? numberPrefixForParagraph(String pPr) {
    final numPr = innerTagBody(pPr, 'numPr');
    if (numPr.isEmpty) return null;
    final numId = wordVal(firstTag(numPr, 'numId') ?? '');
    if (numId == null || numId.isEmpty) return null;
    final level = (int.tryParse(wordVal(firstTag(numPr, 'ilvl') ?? '') ?? '') ?? 0).clamp(0, 8).toInt();
    final levels = numbering[numId];
    final info = levels == null ? null : levels[level];
    final counters = numberingCounters.putIfAbsent(numId, () => List<int>.filled(9, 0));
    if (info == null || info.isBullet) return '•';
    if (level > 0 && currentTopNumber != null && counters[0] != currentTopNumber) {
      counters[0] = currentTopNumber!;
      for (var i = 1; i < counters.length; i++) {
        counters[i] = 0;
      }
    }
    final startAt = info.start <= 0 ? 1 : info.start;
    counters[level] = counters[level] <= 0 ? startAt : counters[level] + 1;
    for (var i = level + 1; i < counters.length; i++) {
      counters[i] = 0;
    }
    if (level == 0) {
      currentTopNumber = counters[0];
      for (final other in numberingCounters.values) {
        other[0] = currentTopNumber!;
        for (var i = 1; i < other.length; i++) {
          other[i] = 0;
        }
      }
      counters[0] = currentTopNumber!;
    }

    var pattern = info.textPattern;
    if (pattern.trim().isEmpty) pattern = '%${level + 1}.';
    for (var i = 0; i <= level; i++) {
      final value = counters[i] <= 0 ? 1 : counters[i];
      pattern = pattern.replaceAll('%${i + 1}', value.toString());
    }
    return pattern;
  }

  String textFromXml(String xml, {bool trim = true}) {
    final buffer = StringBuffer();
    final tokens = RegExp(
      r'<w:tab\b[^>]*/>|<w:br\b[^>]*/>|<w:cr\b[^>]*/>|<w:t\b([^>]*)>(.*?)</w:t>',
      caseSensitive: false,
      dotAll: true,
    );
    for (final token in tokens.allMatches(xml)) {
      final raw = token.group(0) ?? '';
      if (raw.startsWith(RegExp(r'<w:tab', caseSensitive: false))) {
        buffer.write('\u2003\u2003');
      } else if (raw.startsWith(RegExp(r'<w:br|<w:cr', caseSensitive: false))) {
        buffer.write('\n');
      } else {
        final attrs = token.group(1) ?? '';
        final value = _decodeXmlEntities(token.group(2) ?? '');
        if (RegExp(r'''xml:space\s*=\s*["']preserve["']''', caseSensitive: false).hasMatch(attrs)) {
          buffer.write(value.replaceAll('\u00A0', ' '));
        } else {
          buffer.write(value.replaceAll(RegExp(r'[ \t\u00A0]+'), ' '));
        }
      }
    }
    final text = buffer.toString().replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return trim ? text.trim() : text;
  }

  List<_Fb2Inline> inlinesFromParagraphXml(String xml, _OfficeParagraphFormat paragraphFormat) {
    final inlines = <_Fb2Inline>[];
    final runRe = RegExp(r'<w:r\b[^>]*>.*?</w:r>', caseSensitive: false, dotAll: true);
    for (final runMatch in runRe.allMatches(xml)) {
      final run = runMatch.group(0) ?? '';
      final text = textFromXml(run, trim: false);
      if (text.isEmpty) continue;
      final rPr = innerTagBody(run, 'rPr');
      inlines.add(
        _Fb2Inline(
          text,
          bold: onTag(rPr, 'b'),
          italic: onTag(rPr, 'i'),
          underline:
              RegExp(r'<w:u\b', caseSensitive: false).hasMatch(rPr) &&
              !RegExp(r'''<w:u\b[^>]*(?:w:)?val\s*=\s*["']none["']''', caseSensitive: false).hasMatch(rPr),
          fontSize: fontSizeFromRPr(rPr),
          fontFamily: fontFamilyFromRPr(rPr),
          color: colorFromRPr(rPr),
        ),
      );
    }
    if (inlines.isEmpty) {
      final text = textFromXml(xml);
      if (text.isNotEmpty) inlines.add(_Fb2Inline(text, fontSize: paragraphFormat.fontSize));
    }
    return inlines;
  }

  List<Uint8List> imagesFromXml(String xml, Map<String, String> rels) {
    final images = <Uint8List>[];
    final ids = <String>{};
    for (final match in RegExp(
      r'''<(?:a:blip|v:imagedata)\b[^>]*(?:r:embed|r:id)\s*=\s*["']([^"']+)["'][^>]*>''',
      caseSensitive: false,
    ).allMatches(xml)) {
      final id = match.group(1);
      if (id != null && id.isNotEmpty) ids.add(id);
    }
    for (final id in ids) {
      final path = rels[id];
      if (path == null) continue;
      final file = findFile(path);
      if (file != null) images.add(_archiveFileBytes(file));
    }
    return images;
  }

  _OfficeTableFormat tableFormatFromXml(String tblXml) {
    final widths = <int>[];
    final grid = innerTagBody(tblXml, 'tblGrid');
    for (final col in RegExp(r'<w:gridCol\b[^>]*>', caseSensitive: false).allMatches(grid)) {
      final width = intAttr(col.group(0) ?? '', 'w');
      if (width != null && width > 0) widths.add(width);
    }

    final aligns = <List<_OfficeTextAlign?>>[];
    final bold = <List<bool>>[];
    final italic = <List<bool>>[];
    final spans = <List<int>>[];
    for (final row in RegExp(r'<w:tr\b[^>]*>(.*?)</w:tr>', caseSensitive: false, dotAll: true).allMatches(tblXml)) {
      final rowBody = row.group(1) ?? '';
      final rowAligns = <_OfficeTextAlign?>[];
      final rowBold = <bool>[];
      final rowItalic = <bool>[];
      final rowSpans = <int>[];
      for (final cell in RegExp(r'<w:tc\b[^>]*>(.*?)</w:tc>', caseSensitive: false, dotAll: true).allMatches(rowBody)) {
        final cellXml = cell.group(1) ?? '';
        final tcPr = innerTagBody(cellXml, 'tcPr');
        final spanTag = firstTag(tcPr, 'gridSpan') ?? '';
        final span = (int.tryParse(wordVal(spanTag) ?? '') ?? 1).clamp(1, 12).toInt();
        final firstParagraph =
            RegExp(r'<w:p\b[^>]*>.*?</w:p>', caseSensitive: false, dotAll: true).firstMatch(cellXml)?.group(0) ?? '';
        final pPr = innerTagBody(firstParagraph, 'pPr');
        final rPr = innerTagBody(firstParagraph, 'rPr');
        final jc = firstTag(pPr, 'jc');
        final cellAlign = jc == null ? null : alignFromValue(wordVal(jc));
        final cellBold = onTag(rPr, 'b') || RegExp(r'<w:b\b', caseSensitive: false).hasMatch(cellXml);
        final cellItalic = onTag(rPr, 'i') || RegExp(r'<w:i\b', caseSensitive: false).hasMatch(cellXml);
        rowAligns.add(cellAlign);
        rowBold.add(cellBold);
        rowItalic.add(cellItalic);
        rowSpans.add(span);
        for (var extra = 1; extra < span; extra++) {
          rowAligns.add(cellAlign);
          rowBold.add(cellBold);
          rowItalic.add(cellItalic);
          rowSpans.add(0);
        }
      }
      aligns.add(List.unmodifiable(rowAligns));
      bold.add(List.unmodifiable(rowBold));
      italic.add(List.unmodifiable(rowItalic));
      spans.add(List.unmodifiable(rowSpans));
    }
    return _OfficeTableFormat(
      columnTwips: List.unmodifiable(widths),
      cellAligns: List.unmodifiable(aligns),
      cellBold: List.unmodifiable(bold),
      cellItalic: List.unmodifiable(italic),
      cellSpans: List.unmodifiable(spans),
    );
  }

  List<List<String>> tableRowsFromXml(String tblXml) {
    final rows = <List<String>>[];
    for (final row in RegExp(r'<w:tr\b[^>]*>(.*?)</w:tr>', caseSensitive: false, dotAll: true).allMatches(tblXml)) {
      final cells = <String>[];
      final rowBody = row.group(1) ?? '';
      for (final cell in RegExp(r'<w:tc\b[^>]*>(.*?)</w:tc>', caseSensitive: false, dotAll: true).allMatches(rowBody)) {
        final cellXml = cell.group(1) ?? '';
        final tcPr = innerTagBody(cellXml, 'tcPr');
        final spanTag = firstTag(tcPr, 'gridSpan') ?? '';
        final span = (int.tryParse(wordVal(spanTag) ?? '') ?? 1).clamp(1, 12).toInt();
        final vMergeTag = firstTag(tcPr, 'vMerge');
        final vMergeValue = vMergeTag == null ? null : wordVal(vMergeTag)?.toLowerCase();
        final isVMergeContinuation =
            vMergeTag != null && (vMergeValue == null || vMergeValue.isEmpty || vMergeValue == 'continue');
        final cellText = isVMergeContinuation
            ? ''
            : RegExp(r'<w:p\b[^>]*>.*?</w:p>', caseSensitive: false, dotAll: true)
                  .allMatches(cellXml)
                  .map((p) => textFromXml(p.group(0) ?? '', trim: false).trimRight())
                  .join('\n')
                  .replaceAll(RegExp(r'[ \t\u00A0]*\n[ \t\u00A0]*'), '\n')
                  .replaceAll(RegExp(r'[ \t\u00A0]+'), ' ')
                  .trimRight();
        cells.add(cellText.isEmpty ? ' ' : cellText);
        for (var extra = 1; extra < span; extra++) {
          cells.add('');
        }
      }
      // Preserve explicit empty rows: Word tables often use them as layout rows
      // in specifications and signature blanks. Dropping them collapsed the
      // template and removed rows before ИТОГО.
      if (cells.isNotEmpty) rows.add(List.unmodifiable(cells));
    }
    return rows;
  }

  List<_Fb2Block> parsePart(String path, {String? title}) {
    final partBlocks = <_Fb2Block>[];
    final file = findFile(path);
    if (file == null) return partBlocks;
    if (title != null && title.isNotEmpty) partBlocks.add(_Fb2Block.title(title));
    var xml = _decodeTextFile(_archiveFileBytes(file));
    xml = xml.replaceAll(RegExp(r'<w:tab\b[^>]*/>', caseSensitive: false), '<w:tab/>');
    xml = xml.replaceAll(RegExp(r'<w:cr\b[^>]*/>', caseSensitive: false), '<w:cr/>');
    final rels = relationshipsFor(path);

    final blockRe = RegExp(r'<w:tbl\b[^>]*>.*?</w:tbl>|<w:p\b[^>]*>.*?</w:p>', caseSensitive: false, dotAll: true);
    for (final blockMatch in blockRe.allMatches(xml)) {
      final raw = blockMatch.group(0) ?? '';
      for (final image in imagesFromXml(raw, rels)) {
        partBlocks.add(_Fb2Block.image(image));
      }

      if (raw.startsWith(RegExp(r'<w:tbl', caseSensitive: false))) {
        final rows = tableRowsFromXml(raw);
        if (rows.isNotEmpty) partBlocks.add(_Fb2Block.table(rows, officeTableFormat: tableFormatFromXml(raw)));
        continue;
      }

      final hasPageBreak = RegExp(
        r'''<w:br\b[^>]*(?:w:)?type\s*=\s*["']page["'][^>]*/?>''',
        caseSensitive: false,
      ).hasMatch(raw);
      final firstBreakIndex = hasPageBreak ? raw.indexOf(RegExp(r'<w:br\b', caseSensitive: false)) : -1;
      final firstTextIndex = raw.indexOf(RegExp(r'<w:t\b', caseSensitive: false));
      final breakBeforeText = hasPageBreak && (firstTextIndex < 0 || firstBreakIndex < firstTextIndex);
      if (breakBeforeText) {
        partBlocks.add(const _Fb2Block.paragraph([_Fb2Inline(_officePageBreakMarker)]));
      }

      final pPr = innerTagBody(raw, 'pPr');
      final rPr = innerTagBody(raw, 'rPr');
      final styleTag = firstTag(pPr, 'pStyle') ?? '';
      final styleId = wordVal(styleTag);
      final styleFormat = styleId == null
          ? const _OfficeParagraphFormat()
          : (styles[styleId] ?? const _OfficeParagraphFormat());
      var paragraphFormat = formatFromPr(pPr, rPr, base: styleFormat, styleId: styleId);
      final stylePPr = styleId == null ? '' : (styleParagraphProperties[styleId] ?? '');
      final explicitNumber = numberPrefixForParagraph(
        RegExp(r'<w:numPr\b', caseSensitive: false).hasMatch(pPr) ? pPr : stylePPr,
      );
      if (explicitNumber != null && explicitNumber.isNotEmpty) {
        paragraphFormat = paragraphFormat.copyWith(
          isList: true,
          listNumberText: explicitNumber,
          leftIndent: paragraphFormat.leftIndent == 0 ? 28.0 : paragraphFormat.leftIndent,
          firstLineIndent: paragraphFormat.firstLineIndent == 0 ? -18.0 : paragraphFormat.firstLineIndent,
        );
      }
      final inlines = inlinesFromParagraphXml(raw, paragraphFormat);
      final text = inlines.map((inline) => inline.text).join().replaceAll(RegExp(r'[ \t\u00A0]+'), ' ').trim();
      if (text.isNotEmpty) rememberVisibleTopNumber(text);
      if (text.isEmpty && !hasPageBreak && RegExp(r'<w:p\b', caseSensitive: false).hasMatch(raw)) {
        // Preserve intentional blank paragraphs. In contracts and signatures an
        // empty Word paragraph is often layout, not noise.
        partBlocks.add(
          _Fb2Block.paragraph(
            const [_Fb2Inline(' ')],
            officeFormat: paragraphFormat.copyWith(
              fontSize: paragraphFormat.fontSize <= 0 ? 12.0 : paragraphFormat.fontSize,
              lineHeight: paragraphFormat.lineHeight <= 0 ? 1.18 : paragraphFormat.lineHeight,
              spaceBefore: paragraphFormat.spaceBefore == 0 ? 2.0 : paragraphFormat.spaceBefore,
              spaceAfter: paragraphFormat.spaceAfter == 0 ? 9.0 : paragraphFormat.spaceAfter,
            ),
          ),
        );
      }
      if (text.isNotEmpty) {
        if (paragraphFormat.headingLevel > 0) {
          partBlocks.add(_Fb2Block.title(text, officeFormat: paragraphFormat));
        } else if (paragraphFormat.isList &&
            paragraphFormat.listNumberText == null &&
            !text.startsWith('•') &&
            !RegExp(r'^\d+(?:\.\d+)*[.)]?').hasMatch(text)) {
          partBlocks.add(_Fb2Block.paragraph([const _Fb2Inline('• '), ...inlines], officeFormat: paragraphFormat));
        } else {
          partBlocks.add(_Fb2Block.paragraph(inlines, officeFormat: paragraphFormat));
        }
      }

      if (hasPageBreak && !breakBeforeText) {
        partBlocks.add(const _Fb2Block.paragraph([_Fb2Inline(_officePageBreakMarker)]));
      }
    }
    return partBlocks;
  }

  final documentFile = findFile('word/document.xml');
  final documentXml = documentFile == null ? '' : _decodeTextFile(_archiveFileBytes(documentFile));
  final pageFormat = documentXml.isEmpty ? const _OfficePageFormat() : pageFormatFromXml(documentXml);
  final documentRelationships = relationshipsFor('word/document.xml');
  final headerBlocks = <_Fb2Block>[];
  final footerBlocks = <_Fb2Block>[];
  final seenHeaderFooter = <String>{};
  for (final ref in RegExp(
    r'<w:(headerReference|footerReference)\b[^>]*>',
    caseSensitive: false,
  ).allMatches(documentXml)) {
    final tag = ref.group(0) ?? '';
    final kind = (ref.group(1) ?? '').toLowerCase();
    final id = _xmlAttr(tag, 'r:id') ?? wordAttr(tag, 'id');
    final path = id == null ? null : documentRelationships[id];
    if (path == null || !seenHeaderFooter.add('$kind:$path')) continue;
    final parsed = parsePart(path);
    if (kind == 'headerreference') {
      headerBlocks.addAll(parsed);
    } else {
      footerBlocks.addAll(parsed);
    }
  }

  final blocks = <_Fb2Block>[];
  blocks.addAll(parsePart('word/document.xml'));
  blocks.addAll(parsePart('word/footnotes.xml', title: 'Сноски'));
  blocks.addAll(parsePart('word/endnotes.xml', title: 'Примечания'));
  blocks.addAll(parsePart('word/comments.xml', title: 'Комментарии'));
  if (blocks.isEmpty) {
    return _makeFb2Document(
      const [
        _Fb2Block.paragraph([_Fb2Inline('DOCX не содержит извлекаемого текста.')]),
      ],
      officePageFormat: pageFormat,
      officeHeaderBlocks: headerBlocks,
      officeFooterBlocks: footerBlocks,
    );
  }
  return _makeFb2Document(
    blocks,
    officePageFormat: pageFormat,
    officeHeaderBlocks: headerBlocks,
    officeFooterBlocks: footerBlocks,
  );
}

bool _looksLikeZip(Uint8List bytes) => bytes.length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4B;

List<_Fb2Inline> _parseHtmlInlines(String html, String currentPath) {
  final result = <_Fb2Inline>[];
  var cursor = 0;
  final linkRe = RegExp(
    r'''<a\b[^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>''',
    caseSensitive: false,
    dotAll: true,
  );
  for (final match in linkRe.allMatches(html)) {
    final before = _htmlToPlainText(html.substring(cursor, match.start)).trim();
    if (before.isNotEmpty) result.add(_Fb2Inline('$before '));
    final href = _normalizeHtmlHref(match.group(1) ?? '', currentPath);
    final text = _htmlToPlainText(match.group(2) ?? '').trim();
    if (text.isNotEmpty) result.add(_Fb2Inline(text, href: href));
    cursor = match.end;
  }
  final rest = _htmlToPlainText(html.substring(cursor)).trim();
  if (rest.isNotEmpty) result.add(_Fb2Inline(rest));
  return result.isEmpty ? const [_Fb2Inline('')] : result;
}

String _normalizeHtmlHref(String hrefRaw, String currentPath) {
  final href = _decodeXmlEntities(hrefRaw).trim();
  if (href.isEmpty) return href;
  final uri = Uri.tryParse(href);
  if (uri != null && uri.hasScheme) return href;
  final normalizedCurrent = _joinZipPath('', currentPath);
  if (href.startsWith('#')) return '$normalizedCurrent$href';
  return _joinZipPath(_zipDirName(normalizedCurrent), href);
}

List<String> _internalHrefLookupCandidates(String href) {
  final result = <String>{};
  void add(String value) {
    var normalized = value.trim().replaceAll('\\', '/');
    if (normalized.isEmpty) return;
    while (normalized.startsWith('./')) {
      normalized = normalized.substring(2);
    }
    if (normalized.startsWith('/')) normalized = normalized.substring(1);
    result.add(normalized);
    try {
      result.add(Uri.decodeFull(normalized));
    } catch (_) {}
  }

  add(href);
  final uri = Uri.tryParse(href);
  if (uri != null) {
    final path = uri.path;
    final fragment = uri.fragment;
    if (path.isNotEmpty) {
      add(path);
      add(fragment.isEmpty ? path : '$path#$fragment');
    }
    if (fragment.isNotEmpty) {
      add('#$fragment');
      add(fragment);
    }
  }
  final hash = href.indexOf('#');
  if (hash >= 0 && hash < href.length - 1) {
    final path = href.substring(0, hash);
    final fragment = href.substring(hash + 1);
    if (path.isNotEmpty) {
      add(path);
      add('$path#$fragment');
    }
    add('#$fragment');
    add(fragment);
  }
  return result.toList(growable: false);
}

_Fb2Document _parseFb2Document(String xmlText) {
  final xml = _normalizeText(xmlText);
  final binaries = <String, Uint8List>{};
  final binaryRe = RegExp(r'<binary\b([^>]*)>(.*?)</binary>', caseSensitive: false, dotAll: true);
  for (final match in binaryRe.allMatches(xml)) {
    final attrs = match.group(1) ?? '';
    final id = _attr(attrs, 'id');
    if (id == null || id.isEmpty) continue;
    final payload = (match.group(2) ?? '').replaceAll(RegExp(r'\s+'), '');
    try {
      binaries[id] = Uint8List.fromList(base64Decode(payload));
    } catch (_) {}
  }

  var body = xml;
  final bodyMatch = RegExp(r'<body\b[^>]*>(.*?)</body>', caseSensitive: false, dotAll: true).firstMatch(xml);
  if (bodyMatch != null) body = bodyMatch.group(1) ?? body;
  body = body.replaceAll(RegExp(r'<binary\b[^>]*>.*?</binary>', caseSensitive: false, dotAll: true), '');
  body = body.replaceAll(RegExp(r'<description\b[^>]*>.*?</description>', caseSensitive: false, dotAll: true), '');
  body = body.replaceAll(RegExp(r'<empty-line\s*/?>', caseSensitive: false), '<p> </p>');

  final blocks = <_Fb2Block>[];
  var imageBudgetBytes = 24 * 1024 * 1024;
  final blockRe = RegExp(
    r'<image\b[^>]*/>|<title\b[^>]*>.*?</title>|<subtitle\b[^>]*>.*?</subtitle>|<p\b[^>]*>.*?</p>|<v\b[^>]*>.*?</v>',
    caseSensitive: false,
    dotAll: true,
  );
  for (final match in blockRe.allMatches(body)) {
    final raw = match.group(0) ?? '';
    if (raw.startsWith(RegExp(r'<image', caseSensitive: false))) {
      final href = _hrefFromTag(raw);
      final id = href?.replaceFirst('#', '');
      final image = id == null ? null : binaries[id];
      if (image != null && imageBudgetBytes > 0) {
        imageBudgetBytes -= image.length;
        blocks.add(_Fb2Block.image(image));
      }
      continue;
    }
    final isTitle = raw.startsWith(RegExp(r'<title|<subtitle', caseSensitive: false));
    if (isTitle) {
      final text = _stripFb2InlineTags(raw).trim();
      if (text.isNotEmpty) blocks.add(_Fb2Block.title(text));
      final images = RegExp(r'<image\b[^>]*/>', caseSensitive: false).allMatches(raw);
      for (final imageMatch in images) {
        final href = _hrefFromTag(imageMatch.group(0) ?? '');
        final id = href?.replaceFirst('#', '');
        final image = id == null ? null : binaries[id];
        if (image != null && imageBudgetBytes > 0) {
          imageBudgetBytes -= image.length;
          blocks.add(_Fb2Block.image(image));
        }
      }
      continue;
    }
    final images = RegExp(r'<image\b[^>]*/>', caseSensitive: false).allMatches(raw).toList();
    for (final imageMatch in images) {
      final href = _hrefFromTag(imageMatch.group(0) ?? '');
      final id = href?.replaceFirst('#', '');
      final image = id == null ? null : binaries[id];
      if (image != null && imageBudgetBytes > 0) {
        imageBudgetBytes -= image.length;
        blocks.add(_Fb2Block.image(image));
      }
    }
    final inlines = _parseFb2Inlines(raw);
    final text = inlines.map((item) => item.text).join().trim();
    if (text.isNotEmpty) blocks.add(_Fb2Block.paragraph(inlines));
  }

  if (blocks.isEmpty) {
    final text = _extractFb2Text(xml);
    for (final paragraph in text.split(RegExp(r'\n{2,}'))) {
      final trimmed = paragraph.trim();
      if (trimmed.isNotEmpty) blocks.add(_Fb2Block.paragraph([_Fb2Inline(trimmed)]));
    }
  }
  return _makeFb2Document(
    blocks.isEmpty
        ? [
            const _Fb2Block.paragraph([_Fb2Inline('Не удалось извлечь содержимое FB2.')]),
          ]
        : blocks,
  );
}

List<_Fb2Inline> _parseFb2Inlines(String rawBlock) {
  var content = rawBlock.replaceFirst(RegExp(r'^<[^>]+>', caseSensitive: false), '');
  content = content.replaceFirst(RegExp(r'</[^>]+>$', caseSensitive: false), '');
  content = content.replaceAll(RegExp(r'<image\b[^>]*/>', caseSensitive: false), '');
  final result = <_Fb2Inline>[];
  final linkRe = RegExp(r'<a\b([^>]*)>(.*?)</a>', caseSensitive: false, dotAll: true);
  var cursor = 0;
  for (final match in linkRe.allMatches(content)) {
    if (match.start > cursor) {
      final before = _stripFb2InlineTags(content.substring(cursor, match.start));
      if (before.isNotEmpty) result.add(_Fb2Inline(before));
    }
    final href = _hrefFromAttrs(match.group(1) ?? '');
    final linkText = _stripFb2InlineTags(match.group(2) ?? '');
    if (linkText.isNotEmpty) result.add(_Fb2Inline(linkText, href: href));
    cursor = match.end;
  }
  if (cursor < content.length) {
    final rest = _stripFb2InlineTags(content.substring(cursor));
    if (rest.isNotEmpty) result.add(_Fb2Inline(rest));
  }
  return result.isEmpty ? const [_Fb2Inline('')] : result;
}

String _stripFb2InlineTags(String input) {
  var text = input.replaceAll(RegExp(r'<[^>]+>', dotAll: true), '');
  text = _decodeXmlEntities(text);
  return text.replaceAll(RegExp(r'[ \t\u00A0]+'), ' ').trim();
}

String? _hrefFromTag(String tag) => _hrefFromAttrs(tag);

String? _hrefFromAttrs(String attrs) {
  return _attr(attrs, 'l:href') ?? _attr(attrs, 'xlink:href') ?? _attr(attrs, 'href');
}

String? _attr(String attrs, String name) {
  final escaped = RegExp.escape(name);
  final doubleQuoted = RegExp('$escaped\\s*=\\s*"([^"]*)"', caseSensitive: false, dotAll: true).firstMatch(attrs);
  if (doubleQuoted != null) return _decodeXmlEntities(doubleQuoted.group(1) ?? '').trim();
  final singleQuoted = RegExp("$escaped\\s*=\\s*'([^']*)'", caseSensitive: false, dotAll: true).firstMatch(attrs);
  return singleQuoted == null ? null : _decodeXmlEntities(singleQuoted.group(1) ?? '').trim();
}

class _ChmSafeReaderScreen extends StatelessWidget {
  const _ChmSafeReaderScreen({required this.book, required this.storage, required this.sync});

  final BookRecord book;
  final StorageService storage;
  final SyncService sync;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3E7CF),
      appBar: AppBar(title: Text(book.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.archive_outlined, color: Color(0xFF2A2F4A)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'CHM safe mode',
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(color: const Color(0xFF2A2F4A), fontWeight: FontWeight.w800),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'CHM-файл сохранён в библиотеке, но встроенный CHM-адаптер временно отключён, потому что на части файлов он закрывал приложение. '
                      'ReadArc больше не пытается открывать CHM через небезопасный путь. Полноценный CHM будет подключён через processed artifacts так же, как DJVU/DOCX.',
                      style: TextStyle(fontSize: 16, height: 1.45, color: Color(0xFF2A2F4A)),
                    ),
                    const SizedBox(height: 14),
                    Text(book.fileName, style: const TextStyle(fontSize: 13.5, color: Color(0xFF5E6380))),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DjvuReaderScreen extends StatefulWidget {
  const _DjvuReaderScreen({required this.book, required this.storage, required this.sync});

  final BookRecord book;
  final StorageService storage;
  final SyncService sync;

  @override
  State<_DjvuReaderScreen> createState() => _DjvuReaderScreenState();
}

class _DjvuReaderScreenState extends State<_DjvuReaderScreen> {
  static const double _pageAspectRatio = 1.4142;
  static const double _pageGap = 14.0;

  final _scrollController = ScrollController();
  BookRecord? _runtimeBook;
  File? _sourceFile;
  Directory? _pagesDir;
  int _pageCount = 0;
  int _page = 1;
  List<_DjvuPageGeometry> _pageGeometries = const [];
  String? _status;
  String? _error;
  String? _textLayer;
  bool _fullScreen = false;
  bool _djvuProgressScrubActive = false;
  bool _openDjvuPageAtBottom = false;
  bool _restoringScroll = false;
  double _lastViewportWidth = 0;
  Timer? _saveDebounce;

  BookRecord get _book => _runtimeBook ?? widget.book;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    unawaited(_load());
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final manifest = await widget.storage.loadManifest();
      var book = widget.book;
      for (final candidate in manifest.books) {
        if (candidate.id == widget.book.id) {
          book = candidate;
          break;
        }
      }
      if (book.localPath == null || book.localPath!.trim().isEmpty) {
        if (mounted) setState(() => _error = 'DJVU-файл не скачан на это устройство.');
        return;
      }
      final source = File(book.localPath!);
      if (!await source.exists()) {
        if (mounted) setState(() => _error = 'DJVU-файл отсутствует: ${book.localPath}');
        return;
      }
      if (mounted) setState(() => _status = 'Проверяем DJVU и готовим кэш страниц…');
      final artifact = await _prepareDjvuArtifact(book: book, sourceFile: source, storage: widget.storage);
      final geometries = await _readDjvuPageGeometries(
        source,
        artifact.pageCount,
      ).timeout(const Duration(seconds: 10), onTimeout: () => const <_DjvuPageGeometry>[]);
      if (!mounted) return;
      setState(() {
        _runtimeBook = book;
        _sourceFile = source;
        _pagesDir = artifact.pagesDir;
        _pageCount = artifact.pageCount;
        _pageGeometries = geometries;
        _page = _targetPageForBook(book, pages: artifact.pageCount);
        _status = null;
        _error = null;
      });
      _scheduleScrollToPage(_page, animated: false);
      unawaited(_loadTextLayerLater(source));
    } catch (error, stackTrace) {
      debugPrint('DJVU reader load failed: $error\n$stackTrace');
      if (mounted) {
        setState(() {
          _status = null;
          _error = _djvuFriendlyError(error);
        });
      }
    }
  }

  Future<void> _loadTextLayerLater(File sourceFile) async {
    try {
      final textDoc = await _tryExtractDjvuText(sourceFile).timeout(const Duration(seconds: 35));
      final text =
          textDoc?.blocks.map((block) => block.plainText).where((text) => text.trim().isNotEmpty).join('\n\n').trim() ??
          '';
      if (!mounted || text.isEmpty) return;
      setState(() => _textLayer = text);
    } catch (error) {
      debugPrint('DJVU text layer extraction skipped: $error');
    }
  }

  int _targetPageForBook(BookRecord book, {required int pages}) {
    try {
      final decoded = jsonDecode(book.currentLocator);
      if (decoded is Map && (decoded['type'] == 'djvu-page-v2' || decoded['type'] == 'djvu-unit-anchor-v1')) {
        final page = ((decoded['page'] as num?)?.round() ?? 1).clamp(1, pages).toInt();
        return page;
      }
    } catch (_) {}
    final p = book.progressPercent.clamp(0, 100).toDouble();
    if (pages <= 1 || p <= 0) return 1;
    return (1 + ((p / 100.0) * (pages - 1)).round()).clamp(1, pages).toInt();
  }

  void _onScroll() {
    if (_restoringScroll || !_scrollController.hasClients || _pageCount <= 0 || _lastViewportWidth <= 0) return;
    final page = _pageForOffset(_scrollController.offset, _lastViewportWidth).clamp(1, _pageCount).toInt();
    if (page == _page) return;
    setState(() => _page = page);
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 700), () {
      unawaited(_savePage(page));
    });
  }

  double _pageHeight(double viewportWidth) => viewportWidth.clamp(240.0, 1800.0).toDouble() * _pageAspectRatio;

  double _djvuPageDisplayHeight(_DjvuPageGeometry geometry, double viewportWidth) {
    final width = viewportWidth.clamp(240.0, 1800.0).toDouble();
    final ratio = geometry.height <= 0 || geometry.width <= 0 ? _pageAspectRatio : geometry.height / geometry.width;
    return width * ratio.clamp(0.55, 2.2).toDouble();
  }

  double _offsetForPage(int page, double viewportWidth) {
    final safe = page.clamp(1, _pageCount).toInt();
    return 12.0 + (safe - 1) * (_pageHeight(viewportWidth) + _pageGap);
  }

  int _pageForOffset(double offset, double viewportWidth) {
    final itemExtent = _pageHeight(viewportWidth) + _pageGap;
    if (itemExtent <= 0) return 1;
    return (1 + ((offset - 12.0 + itemExtent * 0.45) / itemExtent).floor()).clamp(1, _pageCount).toInt();
  }

  void _scheduleScrollToPage(int page, {required bool animated}) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !_scrollController.hasClients || _lastViewportWidth <= 0) return;
      _restoringScroll = true;
      try {
        final offset = _offsetForPage(page, _lastViewportWidth).clamp(0.0, _scrollController.position.maxScrollExtent);
        if (animated) {
          await _scrollController.animateTo(
            offset,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
          );
        } else {
          _scrollController.jumpTo(offset);
        }
      } finally {
        _restoringScroll = false;
      }
    });
  }

  String _locatorJson(int page) => jsonEncode({
    'type': 'djvu-page-v2',
    'page': page,
    'pages': _pageCount,
    'progressPercent': _progress(page),
    'updatedAt': DateTime.now().toUtc().toIso8601String(),
  });

  double _progress(int page) =>
      _pageCount <= 1 ? 0.0 : (((page - 1) / (_pageCount - 1)) * 100).clamp(0.0, 100.0).toDouble();

  Future<void> _savePage(int page) async {
    await widget.storage.updateProgress(
      bookId: widget.book.id,
      progressPercent: _progress(page),
      locator: _locatorJson(page),
    );
    await widget.sync.broadcastLibrarySnapshot(reason: 'djvu_progress_updated');
  }

  Future<void> _addBookmark() async {
    await widget.storage.addBookmark(
      bookId: widget.book.id,
      label: 'Закладка DJVU, стр. $_page ${DateTime.now().toLocal().toIso8601String().substring(0, 16)}',
      locator: _locatorJson(_page),
    );
    await widget.sync.broadcastLibrarySnapshot(reason: 'bookmark_added');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Закладка добавлена')));
  }

  Future<void> _showDjvuSelectableText() async {
    final text = (_textLayer ?? '').trim();
    if (text.isEmpty || !mounted) return;
    await _showSelectableDocumentText(context, title: _book.title, text: text);
  }

  void _goToDjvuPage(int page, {required bool openAtBottom}) {
    if (_pageCount <= 0) return;
    final next = page.clamp(1, _pageCount).toInt();
    if (next == _page) return;
    setState(() {
      _page = next;
      _openDjvuPageAtBottom = openAtBottom;
    });
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 250), () {
      unawaited(_savePage(next));
    });
  }

  void _setDjvuPageFromProgress(int page) {
    _goToDjvuPage(page, openAtBottom: false);
  }

  void _deactivateDjvuProgressScrub() {
    if (_djvuProgressScrubActive) {
      setState(() => _djvuProgressScrubActive = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final source = _sourceFile;
    final pagesDir = _pagesDir;
    return Scaffold(
      backgroundColor: const Color(0xFFF3E7CF),
      appBar: _fullScreen
          ? null
          : AppBar(
              title: Text(_book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              actions: [
                IconButton(
                  tooltip: 'Полный экран',
                  onPressed: source == null ? null : () => setState(() => _fullScreen = true),
                  icon: const Icon(Icons.fullscreen_rounded),
                ),
                IconButton(
                  tooltip: 'Добавить закладку',
                  onPressed: source == null ? null : _addBookmark,
                  icon: const Icon(Icons.bookmark_add_outlined),
                ),
              ],
            ),
      floatingActionButton: _fullScreen
          ? Padding(
              padding: EdgeInsets.only(bottom: _isAndroidReaderPlatform ? 70 : 0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FloatingActionButton.small(
                    heroTag: 'djvu-bookmark-${widget.book.id}',
                    tooltip: 'Добавить закладку',
                    onPressed: source == null ? null : _addBookmark,
                    child: const Icon(Icons.bookmark_add_outlined),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton.small(
                    heroTag: 'djvu-exit-fullscreen-${widget.book.id}',
                    tooltip: 'Выйти из полного экрана',
                    onPressed: () => setState(() => _fullScreen = false),
                    child: const Icon(Icons.fullscreen_exit_rounded),
                  ),
                ],
              ),
            )
          : null,
      body: _error != null
          ? _ReaderDiagnosticPage(title: 'DJVU не подготовлен', message: _error!)
          : source == null || pagesDir == null || _pageCount <= 0
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(_status ?? 'Открываем DJVU…', textAlign: TextAlign.center),
                ],
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      _lastViewportWidth = constraints.maxWidth;
                      final horizontalInset = _isAndroidReaderPlatform ? 10.0 : 18.0;
                      final displayWidth = (constraints.maxWidth - horizontalInset * 2).clamp(240.0, 1800.0).toDouble();
                      final geometry = (_page - 1) < _pageGeometries.length
                          ? _pageGeometries[_page - 1]
                          : const _DjvuPageGeometry(width: 595, height: 842, dpi: 300);
                      final displayHeight = _djvuPageDisplayHeight(geometry, displayWidth);
                      final dpr = MediaQuery.of(context).devicePixelRatio
                          .clamp(Platform.isAndroid ? 2.75 : 2.0, Platform.isAndroid ? 4.0 : 3.0)
                          .toDouble();
                      return _DjvuSinglePageReader(
                        sourceFile: source,
                        pagesDir: pagesDir,
                        page: _page,
                        pages: _pageCount,
                        displayWidth: displayWidth,
                        displayHeight: displayHeight,
                        devicePixelRatio: dpr,
                        openAtBottom: _openDjvuPageAtBottom,
                        onTapContent: _deactivateDjvuProgressScrub,
                        onLongPressContent: _showDjvuSelectableText,
                        onPrevious: _page <= 1 ? null : () => _goToDjvuPage(_page - 1, openAtBottom: true),
                        onNext: _page >= _pageCount ? null : () => _goToDjvuPage(_page + 1, openAtBottom: false),
                      );
                    },
                  ),
                ),
                if (!_fullScreen)
                  _PagedReaderProgressBar(
                    page: _page,
                    pages: _pageCount,
                    active: _djvuProgressScrubActive,
                    onActivate: () => setState(() => _djvuProgressScrubActive = true),
                    onPageSelected: _setDjvuPageFromProgress,
                  ),
              ],
            ),
    );
  }
}

class _DjvuSinglePageReader extends StatefulWidget {
  const _DjvuSinglePageReader({
    required this.sourceFile,
    required this.pagesDir,
    required this.page,
    required this.pages,
    required this.displayWidth,
    required this.displayHeight,
    required this.devicePixelRatio,
    required this.openAtBottom,
    required this.onTapContent,
    required this.onLongPressContent,
    required this.onPrevious,
    required this.onNext,
  });

  final File sourceFile;
  final Directory pagesDir;
  final int page;
  final int pages;
  final double displayWidth;
  final double displayHeight;
  final double devicePixelRatio;
  final bool openAtBottom;
  final VoidCallback onTapContent;
  final VoidCallback onLongPressContent;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  State<_DjvuSinglePageReader> createState() => _DjvuSinglePageReaderState();
}

class _DjvuSinglePageReaderState extends State<_DjvuSinglePageReader> {
  final _controller = ScrollController();
  final _focusNode = FocusNode(debugLabel: 'ReadArc DJVU paged reader');

  @override
  void initState() {
    super.initState();
    _positionPageAfterFrame();
    if (_isDesktopReaderPlatform) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(covariant _DjvuSinglePageReader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page != widget.page || oldWidget.openAtBottom != widget.openAtBottom) {
      _positionPageAfterFrame();
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _positionPageAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      final target = widget.openAtBottom ? _controller.position.maxScrollExtent : 0.0;
      _controller.jumpTo(target.clamp(0.0, _controller.position.maxScrollExtent));
    });
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity < -240) {
      widget.onNext?.call();
    } else if (velocity > 240) {
      widget.onPrevious?.call();
    }
  }

  void _scrollBy(double delta) {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    final target = (position.pixels + delta).clamp(position.minScrollExtent, position.maxScrollExtent).toDouble();
    _controller.animateTo(target, duration: const Duration(milliseconds: 120), curve: Curves.easeOutCubic);
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (!_isDesktopReaderPlatform || event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft) {
      widget.onPrevious?.call();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      widget.onNext?.call();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _scrollBy(-MediaQuery.of(context).size.height * 0.78);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _scrollBy(MediaQuery.of(context).size.height * 0.78);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final page = Center(
      child: _DjvuPageView(
        key: ValueKey(
          'djvu-page-${widget.page}-${widget.displayWidth.round()}-${widget.devicePixelRatio.toStringAsFixed(2)}',
        ),
        sourceFile: widget.sourceFile,
        pagesDir: widget.pagesDir,
        pageNumber: widget.page,
        pageCount: widget.pages,
        displayWidth: widget.displayWidth,
        displayHeight: widget.displayHeight,
        devicePixelRatio: widget.devicePixelRatio,
      ),
    );

    Widget reader = GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () {
        widget.onTapContent();
        if (_isDesktopReaderPlatform) _focusNode.requestFocus();
      },
      onHorizontalDragEnd: _onHorizontalDragEnd,
      onLongPress: widget.onLongPressContent,
      child: ColoredBox(
        color: const Color(0xFFE9DEC9),
        child: Scrollbar(
          controller: _controller,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _controller,
            padding: const EdgeInsets.fromLTRB(0, 10, 0, 18),
            child: page,
          ),
        ),
      ),
    );

    if (_isAndroidReaderPlatform) {
      reader = Stack(
        children: [
          Positioned.fill(child: reader),
          Positioned.fill(
            child: _PagedReaderAndroidNavButtons(previous: widget.onPrevious, next: widget.onNext),
          ),
        ],
      );
    }

    if (!_isDesktopReaderPlatform) return reader;
    return Focus(focusNode: _focusNode, autofocus: true, onKeyEvent: _handleKeyEvent, child: reader);
  }
}

class _ReaderDiagnosticPage extends StatelessWidget {
  const _ReaderDiagnosticPage({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.error_outline_rounded, color: Color(0xFF8A5B00)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          title,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(color: const Color(0xFF2A2F4A), fontWeight: FontWeight.w800),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(message, style: const TextStyle(fontSize: 16, height: 1.45, color: Color(0xFF2A2F4A))),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DjvuPageGeometry {
  const _DjvuPageGeometry({required this.width, required this.height, required this.dpi});

  final double width;
  final double height;
  final int dpi;
}

Future<List<_DjvuPageGeometry>> _readDjvuPageGeometries(File sourceFile, int pageCount) async {
  if (pageCount <= 0) return const <_DjvuPageGeometry>[];
  try {
    final infos = await DjvuEmbeddedEngine.readPageInfos(sourcePath: sourceFile.path, pageCount: pageCount);
    if (infos.length != pageCount) return const <_DjvuPageGeometry>[];
    return infos
        .map((info) => _DjvuPageGeometry(width: info.width.toDouble(), height: info.height.toDouble(), dpi: info.dpi))
        .toList(growable: false);
  } catch (error) {
    debugPrint('DJVU page geometry read failed: $error');
    return const <_DjvuPageGeometry>[];
  }
}

class _DjvuArtifact {
  const _DjvuArtifact({required this.pageCount, required this.pagesDir});

  final int pageCount;
  final Directory pagesDir;
}

Future<_DjvuArtifact> _prepareDjvuArtifact({
  required BookRecord book,
  required File sourceFile,
  required StorageService storage,
}) async {
  final root = await storage.processedArtifactDir(book.id);
  final pagesDir = Directory('${root.path}${Platform.pathSeparator}pages');
  if (!await pagesDir.exists()) await pagesDir.create(recursive: true);
  final manifestFile = await storage.processedArtifactManifestFile(book.id);
  const renderProfile = 'paged-hidpi-v6-full-canvas-fast';

  // First try an existing processed artifact. This lets Android/opened devices
  // use a prepared DJVU cache once artifact sync is enabled, without needing a
  // embedded renderer locally.
  if (await manifestFile.exists()) {
    try {
      final data = jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
      final cachedPageCount = (data['pageCount'] as num?)?.toInt() ?? 0;
      final firstPage = File('${pagesDir.path}${Platform.pathSeparator}page_00001.png');
      if ((data['kind'] == 'djvu-pages-v1' || data['kind'] == 'djvu-embedded-v1') &&
          data['sourceSha256'] == book.contentSha256 &&
          data['renderProfile'] == renderProfile &&
          cachedPageCount > 0 &&
          await firstPage.exists() &&
          await firstPage.length() > 0) {
        return _DjvuArtifact(pageCount: cachedPageCount, pagesDir: pagesDir);
      }
    } catch (_) {}
  }

  final pageCount = await _readDjvuPageCount(sourceFile);
  if (pageCount == null || pageCount <= 0) {
    throw StateError(
      'ReadArc распознал DJVU как неподготовленный файл, но встроенный probe не смог определить количество страниц. Внешние ddjvu/djvused больше не используются.',
    );
  }

  var reuse = false;
  if (await manifestFile.exists()) {
    try {
      final data = jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
      reuse =
          (data['kind'] == 'djvu-pages-v1' || data['kind'] == 'djvu-embedded-v1') &&
          data['sourceSha256'] == book.contentSha256 &&
          data['renderProfile'] == renderProfile &&
          data['pageCount'] == pageCount;
    } catch (_) {
      reuse = false;
    }
  }
  if (!reuse) {
    if (await pagesDir.exists()) {
      await for (final entity in pagesDir.list(recursive: false, followLinks: false)) {
        try {
          if (entity is File && entity.path.toLowerCase().endsWith('.png')) await entity.delete();
        } catch (_) {}
      }
    }
    const encoder = JsonEncoder.withIndent('  ');
    await manifestFile.writeAsString(
      encoder.convert({
        'kind': 'djvu-embedded-v1',
        'sourceSha256': book.contentSha256,
        'pageCount': pageCount,
        'pageFormat': 'embedded-rgba-cache',
        'renderProfile': renderProfile,
        'rendering': 'embedded-djvu-engine',
        'engine': 'djvu-rs MIT embedded FFI engine',
        'preparedAt': DateTime.now().toUtc().toIso8601String(),
      }),
      flush: true,
    );
  }
  return _DjvuArtifact(pageCount: pageCount, pagesDir: pagesDir);
}

class _DjvuPageView extends StatefulWidget {
  const _DjvuPageView({
    super.key,
    required this.sourceFile,
    required this.pagesDir,
    required this.pageNumber,
    required this.pageCount,
    required this.displayWidth,
    required this.displayHeight,
    required this.devicePixelRatio,
  });

  final File sourceFile;
  final Directory pagesDir;
  final int pageNumber;
  final int pageCount;
  final double displayWidth;
  final double displayHeight;
  final double devicePixelRatio;

  @override
  State<_DjvuPageView> createState() => _DjvuPageViewState();
}

class _DjvuPageViewState extends State<_DjvuPageView> {
  static final Map<String, Future<File?>> _renderJobs = <String, Future<File?>>{};
  static final List<String> _renderOrder = <String>[];
  static Future<void> _queue = Future<void>.value();

  late Future<File?> _imageFuture;

  @override
  void initState() {
    super.initState();
    _resetImageFuture();
  }

  @override
  void didUpdateWidget(covariant _DjvuPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sourceFile.path != widget.sourceFile.path ||
        oldWidget.pageNumber != widget.pageNumber ||
        (oldWidget.displayWidth - widget.displayWidth).abs() > 8 ||
        (oldWidget.devicePixelRatio - widget.devicePixelRatio).abs() > 0.2) {
      _resetImageFuture();
    }
  }

  void _resetImageFuture() {
    _imageFuture = _cachedRender();
    _imageFuture.then((file) {
      if (file != null) unawaited(_precacheAdjacentPages());
    });
  }

  File _pageFile() =>
      File('${widget.pagesDir.path}${Platform.pathSeparator}page_${widget.pageNumber.toString().padLeft(5, '0')}.png');

  Future<File?> _cachedRender() async {
    final out = _pageFile();
    try {
      if (await out.exists() && await out.length() > 0) return out;
    } catch (_) {}
    // DJVU pages often contain scanned text; render above physical DPR and
    // downscale with high filtering. This keeps Android text crisp while the
    // paged viewer limits memory to one visible page plus a small cache.
    final qualityScale = Platform.isAndroid ? 2.05 : 1.75;
    final pixelWidth = (widget.displayWidth * widget.devicePixelRatio * qualityScale)
        .round()
        .clamp(1700, Platform.isAndroid ? 3600 : 3200)
        .toInt();
    final pixelHeight = (widget.displayHeight * widget.devicePixelRatio * qualityScale)
        .round()
        .clamp(2400, Platform.isAndroid ? 5400 : 4800)
        .toInt();
    final key = '${widget.sourceFile.path}:${widget.pageNumber}:$pixelWidth:$pixelHeight';
    final existing = _renderJobs[key];
    if (existing != null) return existing;
    while (_renderOrder.length >= 8) {
      final oldest = _renderOrder.removeAt(0);
      _renderJobs.remove(oldest);
    }
    final job = _enqueueRender(out, pixelWidth, pixelHeight);
    _renderJobs[key] = job;
    _renderOrder.add(key);
    return job;
  }

  Future<void> _precacheAdjacentPages() async {
    final nextPages = <int>[
      widget.pageNumber + 1,
      widget.pageNumber + 2,
      widget.pageNumber + 3,
      widget.pageNumber - 1,
    ].where((page) => page >= 1 && page <= widget.pageCount).toList(growable: false);
    for (final page in nextPages) {
      final out = File('${widget.pagesDir.path}${Platform.pathSeparator}page_${page.toString().padLeft(5, '0')}.png');
      try {
        if (await out.exists() && await out.length() > 0) continue;
      } catch (_) {}
      final qualityScale = Platform.isAndroid ? 2.05 : 1.75;
      final pixelWidth = (widget.displayWidth * widget.devicePixelRatio * qualityScale)
          .round()
          .clamp(1700, Platform.isAndroid ? 3600 : 3200)
          .toInt();
      final pixelHeight = (widget.displayHeight * widget.devicePixelRatio * qualityScale)
          .round()
          .clamp(2400, Platform.isAndroid ? 5400 : 4800)
          .toInt();
      final key = '${widget.sourceFile.path}:$page:$pixelWidth:$pixelHeight';
      if (_renderJobs.containsKey(key)) continue;
      while (_renderOrder.length >= 14) {
        final oldest = _renderOrder.removeAt(0);
        _renderJobs.remove(oldest);
      }
      _renderJobs[key] = _enqueueRender(out, pixelWidth, pixelHeight);
      _renderOrder.add(key);
    }
  }

  Future<File?> _enqueueRender(File out, int pixelWidth, int pixelHeight) {
    final completer = Completer<File?>();
    _queue = _queue.then((_) async {
      try {
        completer.complete(await _render(out, pixelWidth, pixelHeight));
      } catch (error, stackTrace) {
        debugPrint('DJVU page render failed: $error\n$stackTrace');
        completer.complete(null);
      }
    });
    return completer.future;
  }

  Future<File?> _render(File out, int pixelWidth, int pixelHeight) async {
    try {
      if (await out.exists() && await out.length() > 0) return out;
    } catch (_) {}
    final png = await DjvuEmbeddedEngine.renderPagePng(
      sourcePath: widget.sourceFile.path,
      pageNumber: widget.pageNumber,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
    ).timeout(const Duration(seconds: 45), onTimeout: () => null);
    if (png == null || png.isEmpty) return null;
    await out.writeAsBytes(png, flush: true);
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.displayWidth,
      height: widget.displayHeight,
      child: FutureBuilder<File?>(
        future: _imageFuture,
        builder: (context, snapshot) {
          final file = snapshot.data;
          if (file == null) {
            if (snapshot.connectionState == ConnectionState.done) {
              return const _DjvuPageSheet(
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.all(18),
                    child: Text(
                      'Не удалось отрисовать страницу DJVU встроенным движком ReadArc. Проверьте, что native engine вошёл в сборку.',
                    ),
                  ),
                ),
              );
            }
            return const _DjvuPageSheet(child: Center(child: CircularProgressIndicator()));
          }
          return _DjvuPageSheet(
            child: Image.file(
              file,
              width: widget.displayWidth,
              height: widget.displayHeight,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              filterQuality: FilterQuality.high,
              isAntiAlias: true,
            ),
          );
        },
      ),
    );
  }
}

class _DjvuPageSheet extends StatelessWidget {
  const _DjvuPageSheet({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.black.withValues(alpha: 0.34), width: 1.1),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.22), blurRadius: 8, offset: const Offset(0, 3))],
      ),
      child: ClipRect(child: child),
    );
  }
}

String _djvuFriendlyError(Object error) {
  final message = '$error';
  return '$message\n\nReadArc больше не использует внешние ddjvu/djvused/djvutxt. Для DJVU выбран встроенный путь: pure Rust djvu-rs через native/FFI engine. Приложение должно оставаться открытым и показывать диагностику внутри reader-а.';
}

class _PdfReaderScreen extends StatefulWidget {
  const _PdfReaderScreen({required this.book, required this.storage, required this.sync});

  final BookRecord book;
  final StorageService storage;
  final SyncService sync;

  @override
  State<_PdfReaderScreen> createState() => _PdfReaderScreenState();
}

class _PdfReaderScreenState extends State<_PdfReaderScreen> {
  PdfDocument? _document;
  final _scrollController = ScrollController();
  BookRecord? _runtimeBook;
  int _page = 1;
  int _pages = 0;
  List<_PdfPageGeometry> _pageGeometries = const [];
  String? _loadError;
  String? _textLayer;
  Timer? _saveDebounce;
  Timer? _scrollRedrawThrottle;
  bool _textLayerLoading = false;
  bool _fullScreen = false;
  bool _pdfProgressScrubActive = false;
  bool _openPdfPageAtBottom = false;
  double _lastViewportWidth = 0;

  BookRecord get _book => _runtimeBook ?? widget.book;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onPdfScroll);
    unawaited(_load());
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _scrollRedrawThrottle?.cancel();
    _scrollController.removeListener(_onPdfScroll);
    _scrollController.dispose();
    final document = _document;
    if (document != null) unawaited(Future<void>.sync(() => document.close()));
    super.dispose();
  }

  Future<void> _load() async {
    final manifest = await widget.storage.loadManifest();
    var book = widget.book;
    for (final candidate in manifest.books) {
      if (candidate.id == widget.book.id) {
        book = candidate;
        break;
      }
    }
    if (book.localPath == null) {
      if (mounted) setState(() => _loadError = 'Файл PDF не скачан на это устройство');
      return;
    }
    final file = File(book.localPath!);
    if (!await file.exists()) {
      if (mounted) setState(() => _loadError = 'Файл PDF отсутствует: ${book.localPath}');
      return;
    }
    try {
      final doc = await PdfDocument.openFile(file.path).timeout(const Duration(seconds: 15));
      final pages = doc.pagesCount;
      final geometries = await _readPdfPageGeometries(doc, pages).timeout(const Duration(seconds: 8));
      final initialPage = _targetPageForBook(book, pages: pages);
      if (!mounted) {
        unawaited(Future<void>.sync(() => doc.close()));
        return;
      }
      setState(() {
        _runtimeBook = book;
        _page = initialPage;
        _pages = pages;
        _pageGeometries = geometries;
        _document = doc;
        _textLayer = '';
        _loadError = null;
      });
      // PDF is now always opened in page-by-page mode. Text extraction is kept
      // asynchronous and moved to a background isolate so large PDFs do not block
      // the reader UI.
      unawaited(_loadPdfTextLayerLater(file));
    } catch (error) {
      if (mounted) setState(() => _loadError = 'Не удалось открыть PDF: $error');
    }
  }

  Future<void> _loadPdfTextLayerLater(File file) async {
    if (_textLayerLoading) return;
    _textLayerLoading = true;
    try {
      final textLayer = await _extractPdfTextLayer(file).timeout(const Duration(seconds: 45), onTimeout: () => '');
      if (!mounted) return;
      if (textLayer.trim().isNotEmpty) setState(() => _textLayer = textLayer);
    } catch (error) {
      debugPrint('ReadArc PDF text layer extraction skipped: $error');
    } finally {
      _textLayerLoading = false;
    }
  }

  Future<List<_PdfPageGeometry>> _readPdfPageGeometries(PdfDocument doc, int pages) async {
    if (pages <= 0) return const [];
    _PdfPageGeometry fallback = const _PdfPageGeometry(width: 595, height: 842);
    try {
      final first = await doc.getPage(1).timeout(const Duration(seconds: 4));
      fallback = _PdfPageGeometry(width: first.width.toDouble(), height: first.height.toDouble());
      await Future<void>.sync(() => first.close());
    } catch (_) {}
    // Do not probe every page during open. Large PDFs can have hundreds of
    // pages; asking pdfium for each geometry made both macOS and Android look
    // frozen before the first page was visible. Most books use a stable page
    // size, so the first page is a safe fast estimate and individual rendered
    // pages still come from the real PDF.
    return List<_PdfPageGeometry>.filled(pages, fallback, growable: false);
  }

  int _targetPageForBook(BookRecord book, {required int pages}) {
    try {
      final decoded = jsonDecode(book.currentLocator);
      if (decoded is Map && decoded['type'] == 'pdf-page-v1') {
        final page = ((decoded['page'] as num?)?.round() ?? 1).clamp(1, pages).toInt();
        return page;
      }
    } catch (_) {}
    final p = book.progressPercent.clamp(0, 100).toDouble();
    if (pages <= 1 || p <= 0) return 1;
    return (1 + ((p / 100.0) * (pages - 1)).round()).clamp(1, pages).toInt();
  }

  void _onPdfScroll() {
    if (!_scrollController.hasClients || _pages <= 0 || _lastViewportWidth <= 0) return;
    final page = _pageForOffset(_scrollController.offset, _lastViewportWidth).clamp(1, _pages).toInt();
    if (page != _page) {
      _page = page;
      if (!(_scrollRedrawThrottle?.isActive ?? false)) {
        _scrollRedrawThrottle = Timer(const Duration(milliseconds: 80), () {
          if (mounted) setState(() {});
        });
      }
      _saveDebounce?.cancel();
      _saveDebounce = Timer(const Duration(milliseconds: 500), () {
        unawaited(_savePage(page));
      });
    }
  }

  String _pdfLocatorJson(int page) {
    final progress = _pdfProgress(page);
    return jsonEncode({
      'type': 'pdf-page-v1',
      'page': page,
      'pages': _pages,
      'progressPercent': progress,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    });
  }

  double _pdfProgress(int page) {
    final pages = _pages;
    return pages <= 1 ? 0.0 : (((page - 1) / (pages - 1)) * 100).clamp(0.0, 100.0).toDouble();
  }

  Future<void> _savePage(int page) async {
    await widget.storage.updateProgress(
      bookId: widget.book.id,
      progressPercent: _pdfProgress(page),
      locator: _pdfLocatorJson(page),
    );
    await widget.sync.broadcastLibrarySnapshot(reason: 'pdf_progress_updated');
  }

  Future<void> _addBookmark() async {
    await widget.storage.addBookmark(
      bookId: widget.book.id,
      label: 'Закладка PDF, стр. $_page ${DateTime.now().toLocal().toIso8601String().substring(0, 16)}',
      locator: _pdfLocatorJson(_page),
    );
    await widget.sync.broadcastLibrarySnapshot(reason: 'bookmark_added');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Закладка добавлена')));
  }

  Future<void> _showPdfSelectableText() async {
    final text = (_textLayer ?? '').trim();
    if (text.isEmpty || !mounted) return;
    await _showSelectableDocumentText(context, title: _book.title, text: text);
  }

  double _pdfPageDisplayHeight(_PdfPageGeometry geometry, double viewportWidth) {
    final width = viewportWidth.clamp(220.0, 2200.0).toDouble();
    final ratio = geometry.height <= 0 || geometry.width <= 0 ? 1.414 : geometry.height / geometry.width;
    return width * ratio;
  }

  void _goToPdfPage(int page, {required bool openAtBottom}) {
    if (_pages <= 0) return;
    final next = page.clamp(1, _pages).toInt();
    if (next == _page) return;
    setState(() {
      _page = next;
      _openPdfPageAtBottom = openAtBottom;
    });
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 250), () {
      unawaited(_savePage(next));
    });
  }

  void _setPdfPageFromProgress(int page) {
    _goToPdfPage(page, openAtBottom: false);
  }

  void _deactivatePdfProgressScrub() {
    if (_pdfProgressScrubActive) {
      setState(() => _pdfProgressScrubActive = false);
    }
  }

  int _pageForOffset(double offset, double viewportWidth) {
    if (_pageGeometries.isEmpty) return 1;
    var cursor = 12.0;
    for (var i = 0; i < _pageGeometries.length; i++) {
      final height = _pdfPageDisplayHeight(_pageGeometries[i], viewportWidth) + 12.0;
      if (offset < cursor + height * 0.62) return i + 1;
      cursor += height;
    }
    return _pageGeometries.length;
  }

  @override
  Widget build(BuildContext context) {
    final document = _document;
    return Scaffold(
      backgroundColor: const Color(0xFFF3E7CF),
      appBar: _fullScreen
          ? null
          : AppBar(
              title: Text(_book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              actions: [
                IconButton(
                  tooltip: 'Полный экран',
                  onPressed: () => setState(() => _fullScreen = true),
                  icon: const Icon(Icons.fullscreen_rounded),
                ),
                IconButton(
                  tooltip: 'Добавить закладку',
                  onPressed: document != null ? _addBookmark : null,
                  icon: const Icon(Icons.bookmark_add_outlined),
                ),
              ],
            ),
      floatingActionButton: _fullScreen
          ? Padding(
              padding: EdgeInsets.only(bottom: _isAndroidReaderPlatform ? 70 : 0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FloatingActionButton.small(
                    heroTag: 'pdf-bookmark-${widget.book.id}',
                    tooltip: 'Добавить закладку',
                    onPressed: document != null ? _addBookmark : null,
                    child: const Icon(Icons.bookmark_add_outlined),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton.small(
                    heroTag: 'pdf-exit-fullscreen-${widget.book.id}',
                    tooltip: 'Выйти из полного экрана',
                    onPressed: () => setState(() => _fullScreen = false),
                    child: const Icon(Icons.fullscreen_exit_rounded),
                  ),
                ],
              ),
            )
          : null,
      body: _loadError != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Text(_loadError!, textAlign: TextAlign.center),
              ),
            )
          : document == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      _lastViewportWidth = constraints.maxWidth;
                      final dpr = MediaQuery.of(context).devicePixelRatio
                          .clamp(Platform.isAndroid ? 2.25 : 1.75, Platform.isAndroid ? 3.25 : 2.5)
                          .toDouble();
                      final geometry = (_page - 1) < _pageGeometries.length
                          ? _pageGeometries[_page - 1]
                          : const _PdfPageGeometry(width: 595, height: 842);
                      final displayWidth = constraints.maxWidth.clamp(220.0, 1800.0).toDouble();
                      final displayHeight = _pdfPageDisplayHeight(geometry, displayWidth);
                      return _LargePdfSinglePageReader(
                        document: document,
                        page: _page,
                        pages: _pages,
                        displayWidth: displayWidth,
                        displayHeight: displayHeight,
                        devicePixelRatio: dpr,
                        openAtBottom: _openPdfPageAtBottom,
                        onTapContent: _deactivatePdfProgressScrub,
                        onLongPressContent: _showPdfSelectableText,
                        onPrevious: _page <= 1 ? null : () => _goToPdfPage(_page - 1, openAtBottom: true),
                        onNext: _page >= _pages ? null : () => _goToPdfPage(_page + 1, openAtBottom: false),
                      );
                    },
                  ),
                ),
                if (!_fullScreen)
                  _PagedReaderProgressBar(
                    page: _page,
                    pages: _pages,
                    active: _pdfProgressScrubActive,
                    onActivate: () => setState(() => _pdfProgressScrubActive = true),
                    onPageSelected: _setPdfPageFromProgress,
                  ),
              ],
            ),
    );
  }
}

class _LargePdfSinglePageReader extends StatefulWidget {
  const _LargePdfSinglePageReader({
    required this.document,
    required this.page,
    required this.pages,
    required this.displayWidth,
    required this.displayHeight,
    required this.devicePixelRatio,
    required this.openAtBottom,
    required this.onTapContent,
    required this.onLongPressContent,
    required this.onPrevious,
    required this.onNext,
  });

  final PdfDocument document;
  final int page;
  final int pages;
  final double displayWidth;
  final double displayHeight;
  final double devicePixelRatio;
  final bool openAtBottom;
  final VoidCallback onTapContent;
  final VoidCallback onLongPressContent;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  State<_LargePdfSinglePageReader> createState() => _LargePdfSinglePageReaderState();
}

class _LargePdfSinglePageReaderState extends State<_LargePdfSinglePageReader> {
  final _controller = ScrollController();
  final _focusNode = FocusNode(debugLabel: 'ReadArc PDF paged reader');

  @override
  void initState() {
    super.initState();
    _positionPageAfterFrame();
    if (_isDesktopReaderPlatform) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(covariant _LargePdfSinglePageReader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page != widget.page || oldWidget.openAtBottom != widget.openAtBottom) {
      _positionPageAfterFrame();
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _positionPageAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      final target = widget.openAtBottom ? _controller.position.maxScrollExtent : 0.0;
      _controller.jumpTo(target.clamp(0.0, _controller.position.maxScrollExtent));
    });
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity < -240) {
      widget.onNext?.call();
    } else if (velocity > 240) {
      widget.onPrevious?.call();
    }
  }

  void _scrollBy(double delta) {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    final target = (position.pixels + delta).clamp(position.minScrollExtent, position.maxScrollExtent).toDouble();
    _controller.animateTo(target, duration: const Duration(milliseconds: 120), curve: Curves.easeOutCubic);
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (!_isDesktopReaderPlatform || event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft) {
      widget.onPrevious?.call();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      widget.onNext?.call();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _scrollBy(-MediaQuery.of(context).size.height * 0.78);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _scrollBy(MediaQuery.of(context).size.height * 0.78);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final page = Center(
      child: _PdfFitWidthPage(
        key: ValueKey(
          'pdf-page-${widget.page}-${widget.displayWidth.round()}-${widget.devicePixelRatio.toStringAsFixed(2)}',
        ),
        document: widget.document,
        pageNumber: widget.page,
        displayWidth: widget.displayWidth,
        displayHeight: widget.displayHeight,
        devicePixelRatio: widget.devicePixelRatio,
      ),
    );

    Widget reader = GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () {
        widget.onTapContent();
        if (_isDesktopReaderPlatform) _focusNode.requestFocus();
      },
      onHorizontalDragEnd: _onHorizontalDragEnd,
      onLongPress: widget.onLongPressContent,
      child: ColoredBox(
        color: const Color(0xFFF3E7CF),
        child: Scrollbar(
          controller: _controller,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _controller,
            padding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
            child: page,
          ),
        ),
      ),
    );

    if (_isAndroidReaderPlatform) {
      reader = Stack(
        children: [
          Positioned.fill(child: reader),
          Positioned.fill(
            child: _PagedReaderAndroidNavButtons(previous: widget.onPrevious, next: widget.onNext),
          ),
        ],
      );
    }

    if (!_isDesktopReaderPlatform) return reader;
    return Focus(focusNode: _focusNode, autofocus: true, onKeyEvent: _handleKeyEvent, child: reader);
  }
}

class _ContinuousReaderProgressBar extends StatefulWidget {
  const _ContinuousReaderProgressBar({
    required this.progress,
    required this.label,
    required this.active,
    required this.onActivate,
    required this.onFractionSelected,
  });

  final double progress;
  final String label;
  final bool active;
  final VoidCallback onActivate;
  final ValueChanged<double> onFractionSelected;

  @override
  State<_ContinuousReaderProgressBar> createState() => _ContinuousReaderProgressBarState();
}

class _ContinuousReaderProgressBarState extends State<_ContinuousReaderProgressBar> {
  bool _hover = false;
  bool _dragging = false;
  double? _previewFraction;
  double? _previewDx;

  bool get _desktopHoverMode => _isDesktopReaderPlatform;
  bool get _interactive => widget.active || (_desktopHoverMode && _hover) || _dragging;
  double get _displayFraction => (_previewFraction ?? widget.progress).clamp(0.0, 1.0).toDouble();

  void _handlePosition(Offset localPosition, double width) {
    if (width <= 0) return;
    final fraction = (localPosition.dx / width).clamp(0.0, 1.0).toDouble();
    setState(() {
      _previewFraction = fraction;
      _previewDx = localPosition.dx.clamp(0.0, width).toDouble();
    });
    widget.onFractionSelected(fraction);
  }

  void _finishPreview() {
    if (!_dragging && _previewFraction == null) return;
    setState(() {
      _dragging = false;
      if (!_desktopHoverMode || !_hover) {
        _previewFraction = null;
        _previewDx = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final active = _interactive;
    const indigo = _raInkBlue;
    const gold = _raWarmGold;
    final hitAreaHeight = _isDesktopReaderPlatform ? 34.0 : 46.0;
    final visualHeight = active ? 6.0 : 3.0;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 2, 14, 5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MouseRegion(
              onEnter: (_) {
                if (_desktopHoverMode) setState(() => _hover = true);
              },
              onExit: (_) {
                if (_desktopHoverMode) {
                  setState(() {
                    _hover = false;
                    _previewFraction = null;
                    _previewDx = null;
                  });
                }
              },
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final bubbleVisible = active && (_dragging || widget.active || (_desktopHoverMode && _hover));
                  final bubbleLeft = ((_previewDx ?? (_displayFraction * constraints.maxWidth)) - 32)
                      .clamp(0.0, (constraints.maxWidth - 64).clamp(0.0, constraints.maxWidth))
                      .toDouble();
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (details) {
                      setState(() => _dragging = true);
                      if (_desktopHoverMode) {
                        _handlePosition(details.localPosition, constraints.maxWidth);
                        return;
                      }
                      if (!widget.active) {
                        widget.onActivate();
                        _handlePosition(details.localPosition, constraints.maxWidth);
                        return;
                      }
                      _handlePosition(details.localPosition, constraints.maxWidth);
                    },
                    onTapUp: (_) => _finishPreview(),
                    onTapCancel: _finishPreview,
                    onHorizontalDragStart: (details) {
                      setState(() => _dragging = true);
                      if (!_desktopHoverMode && !widget.active) widget.onActivate();
                      _handlePosition(details.localPosition, constraints.maxWidth);
                    },
                    onHorizontalDragUpdate: (details) {
                      if (_desktopHoverMode || widget.active || _dragging) {
                        _handlePosition(details.localPosition, constraints.maxWidth);
                      }
                    },
                    onHorizontalDragEnd: (_) => _finishPreview(),
                    onHorizontalDragCancel: _finishPreview,
                    child: SizedBox(
                      height: hitAreaHeight + (bubbleVisible ? 28 : 0),
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          if (bubbleVisible)
                            Positioned(
                              left: bubbleLeft,
                              top: 0,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: indigo.withValues(alpha: 0.92),
                                  borderRadius: BorderRadius.circular(999),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.16),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  child: Text(
                                    '${(_displayFraction * 100).clamp(0, 100).toStringAsFixed(1)}%',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 130),
                              height: hitAreaHeight,
                              padding: EdgeInsets.symmetric(vertical: (hitAreaHeight - visualHeight) / 2),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(999),
                                child: LinearProgressIndicator(
                                  value: _displayFraction,
                                  minHeight: visualHeight,
                                  valueColor: AlwaysStoppedAnimation<Color>(active ? indigo : gold),
                                  backgroundColor: active
                                      ? indigo.withValues(alpha: 0.20)
                                      : gold.withValues(alpha: 0.20),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                widget.label,
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: indigo),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PagedReaderProgressBar extends StatefulWidget {
  const _PagedReaderProgressBar({
    required this.page,
    required this.pages,
    required this.active,
    required this.onActivate,
    required this.onPageSelected,
  });

  final int page;
  final int pages;
  final bool active;
  final VoidCallback onActivate;
  final ValueChanged<int> onPageSelected;

  @override
  State<_PagedReaderProgressBar> createState() => _PagedReaderProgressBarState();
}

class _PagedReaderProgressBarState extends State<_PagedReaderProgressBar> {
  bool _hover = false;

  bool get _desktopHoverMode => _isDesktopReaderPlatform;
  bool get _interactive => widget.active || (_desktopHoverMode && _hover);

  void _handlePosition(Offset localPosition, double width) {
    if (widget.pages <= 1 || width <= 0) return;
    final fraction = (localPosition.dx / width).clamp(0.0, 1.0).toDouble();
    final next = (1 + (fraction * (widget.pages - 1)).round()).clamp(1, widget.pages).toInt();
    widget.onPageSelected(next);
  }

  @override
  Widget build(BuildContext context) {
    final progress = widget.pages <= 1 ? 0.0 : ((widget.page - 1) / (widget.pages - 1)).clamp(0.0, 1.0).toDouble();
    final active = _interactive;
    const indigo = _raInkBlue;
    const gold = _raWarmGold;
    final hitAreaHeight = _isDesktopReaderPlatform ? 34.0 : 46.0;
    final visualHeight = active ? 6.0 : 3.0;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 2, 14, 5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MouseRegion(
              onEnter: (_) {
                if (_desktopHoverMode) setState(() => _hover = true);
              },
              onExit: (_) {
                if (_desktopHoverMode) setState(() => _hover = false);
              },
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (details) {
                      if (_desktopHoverMode) {
                        _handlePosition(details.localPosition, constraints.maxWidth);
                        return;
                      }
                      if (!widget.active) {
                        widget.onActivate();
                        return;
                      }
                      _handlePosition(details.localPosition, constraints.maxWidth);
                    },
                    onHorizontalDragStart: (_) {
                      if (!_desktopHoverMode && !widget.active) widget.onActivate();
                    },
                    onHorizontalDragUpdate: (details) {
                      if (_desktopHoverMode || widget.active) {
                        _handlePosition(details.localPosition, constraints.maxWidth);
                      }
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 130),
                      height: hitAreaHeight,
                      padding: EdgeInsets.symmetric(vertical: (hitAreaHeight - visualHeight) / 2),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: visualHeight,
                          valueColor: AlwaysStoppedAnimation<Color>(active ? indigo : gold),
                          backgroundColor: active ? indigo.withValues(alpha: 0.20) : gold.withValues(alpha: 0.20),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                widget.pages > 0 ? '${widget.page} / ${widget.pages}' : '${widget.page}',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: indigo),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PagedReaderAndroidNavButtons extends StatelessWidget {
  const _PagedReaderAndroidNavButtons({required this.previous, required this.next});

  final VoidCallback? previous;
  final VoidCallback? next;

  @override
  Widget build(BuildContext context) {
    if (!_isAndroidReaderPlatform) return const SizedBox.shrink();
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _AndroidPageTurnButton(icon: Icons.chevron_left_rounded, onPressed: previous),
              _AndroidPageTurnButton(icon: Icons.chevron_right_rounded, onPressed: next),
            ],
          ),
        ),
      ),
    );
  }
}

class _AndroidPageTurnButton extends StatelessWidget {
  const _AndroidPageTurnButton({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Material(
      color: _raWarmGold.withValues(alpha: enabled ? 0.20 : 0.08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(17),
        side: BorderSide(color: _raWarmGold.withValues(alpha: enabled ? 0.34 : 0.12), width: 0.8),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(17),
        onTap: onPressed,
        child: SizedBox(
          width: 50,
          height: 38,
          child: Icon(icon, size: 27, color: _raWarmGold.withValues(alpha: enabled ? 0.92 : 0.24)),
        ),
      ),
    );
  }
}

Future<void> _showSelectableDocumentText(BuildContext context, {required String title, required String text}) async {
  final content = text.trim();
  if (content.isEmpty) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: _raPaper,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (context) {
      return SafeArea(
        child: Padding(
          padding: EdgeInsets.only(left: 18, right: 18, top: 14, bottom: 18 + MediaQuery.of(context).viewInsets.bottom),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.78),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(color: _raInkBlue, fontWeight: FontWeight.w800),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Закрыть',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded, color: _raInkBlue),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: SingleChildScrollView(
                    child: SelectionArea(
                      child: Text(content, style: const TextStyle(color: _raInkBlue, height: 1.45, fontSize: 15)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _PdfPageGeometry {
  const _PdfPageGeometry({required this.width, required this.height});

  final double width;
  final double height;
}

class _PdfFitWidthPage extends StatefulWidget {
  const _PdfFitWidthPage({
    super.key,
    required this.document,
    required this.pageNumber,
    required this.displayWidth,
    required this.displayHeight,
    required this.devicePixelRatio,
  });

  final PdfDocument document;
  final int pageNumber;
  final double displayWidth;
  final double displayHeight;
  final double devicePixelRatio;

  @override
  State<_PdfFitWidthPage> createState() => _PdfFitWidthPageState();
}

class _PdfFitWidthPageState extends State<_PdfFitWidthPage> {
  static final Map<String, Future<Uint8List?>> _renderCache = <String, Future<Uint8List?>>{};
  static final List<String> _renderCacheOrder = <String>[];
  static Future<void> _renderQueue = Future<void>.value();

  late Future<Uint8List?> _imageFuture;

  @override
  void initState() {
    super.initState();
    _imageFuture = _cachedRender();
  }

  @override
  void didUpdateWidget(covariant _PdfFitWidthPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.document != widget.document ||
        oldWidget.pageNumber != widget.pageNumber ||
        (oldWidget.displayWidth - widget.displayWidth).abs() > 2 ||
        (oldWidget.devicePixelRatio - widget.devicePixelRatio).abs() > 0.1) {
      _imageFuture = _cachedRender();
    }
  }

  Future<Uint8List?> _cachedRender() {
    final pixelWidth = (widget.displayWidth * widget.devicePixelRatio).round().clamp(
      720,
      Platform.isAndroid ? 2600 : 2400,
    );
    final pixelHeight = (widget.displayHeight * widget.devicePixelRatio).round().clamp(
      960,
      Platform.isAndroid ? 3900 : 3400,
    );
    final key = '${identityHashCode(widget.document)}:${widget.pageNumber}:$pixelWidth:$pixelHeight';
    final existing = _renderCache[key];
    if (existing != null) return existing;
    final maxCachedPages = Platform.isAndroid ? 2 : 3;
    while (_renderCacheOrder.length >= maxCachedPages) {
      final oldest = _renderCacheOrder.removeAt(0);
      _renderCache.remove(oldest);
    }
    final future = _queuedRender(pixelWidth.toDouble(), pixelHeight.toDouble());
    _renderCache[key] = future;
    _renderCacheOrder.add(key);
    return future;
  }

  Future<Uint8List?> _queuedRender(double pixelWidth, double pixelHeight) {
    final completer = Completer<Uint8List?>();
    _renderQueue = _renderQueue.then((_) async {
      try {
        completer.complete(
          await _render(pixelWidth, pixelHeight).timeout(const Duration(seconds: 20), onTimeout: () => null),
        );
      } catch (error, stackTrace) {
        debugPrint('PDF page render failed: $error\n$stackTrace');
        completer.complete(null);
      }
    });
    return completer.future;
  }

  Future<Uint8List?> _render(double pixelWidth, double pixelHeight) async {
    final page = await widget.document.getPage(widget.pageNumber);
    try {
      final image = await page.render(
        width: pixelWidth,
        height: pixelHeight,
        format: PdfPageImageFormat.png,
        backgroundColor: '#FFFFFF',
      );
      return image?.bytes;
    } finally {
      await Future<void>.sync(() => page.close());
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.displayWidth,
      height: widget.displayHeight,
      child: FutureBuilder<Uint8List?>(
        future: _imageFuture,
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          if (bytes == null) {
            return const ColoredBox(
              color: Color(0xFFF8F1E3),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          return Image.memory(
            bytes,
            width: widget.displayWidth,
            height: widget.displayHeight,
            fit: BoxFit.fill,
            gaplessPlayback: true,
            filterQuality: FilterQuality.high,
            isAntiAlias: true,
          );
        },
      ),
    );
  }
}

Future<String> _extractPdfTextLayer(File file) async {
  try {
    final bytes = await file.readAsBytes();
    return await compute(_extractPdfTextFromBytes, bytes);
  } catch (_) {
    return '';
  }
}

String _extractPdfTextFromBytes(Uint8List bytes) {
  final chunks = <String>[];

  // First pass: PDF content streams are very often compressed with FlateDecode.
  // The previous extractor only scanned the raw PDF bytes, so the copy button
  // stayed disabled for most real text PDFs. Decode streams in pure Dart and
  // extract BT/ET text operators from the decompressed page content.
  for (final stream in _extractPdfDecodedStreams(bytes)) {
    final text = _extractPdfTextFromContent(stream);
    if (text.trim().isNotEmpty) chunks.add(text);
  }

  // Fallback for uncompressed/simple PDFs and metadata text.
  final source = latin1.decode(bytes, allowInvalid: true);
  for (final object in RegExp(r'BT\b(.*?)\bET', dotAll: true).allMatches(source)) {
    chunks.add(_extractPdfTextFromContent(object.group(1) ?? ''));
  }
  if (chunks.isEmpty) {
    chunks.add(_extractPdfTextFromContent(source));
  }
  final normalized = _normalizeExtractedPdfText(chunks.where((chunk) => chunk.trim().isNotEmpty).join('\n'));
  if (!_looksLikeReadableDocumentPreview(normalized, minLetters: 30, minWords: 8)) return '';
  return normalized;
}

List<String> _extractPdfDecodedStreams(Uint8List bytes) {
  final result = <String>[];
  final source = latin1.decode(bytes, allowInvalid: true);
  final streamRe = RegExp(r'<<(.*?)>>\s*stream\r?\n', dotAll: true);
  for (final match in streamRe.allMatches(source)) {
    final dict = match.group(1) ?? '';
    final streamStart = match.end;
    final endMarker = source.indexOf('endstream', streamStart);
    if (endMarker <= streamStart) continue;
    var dataStart = streamStart;
    var dataEnd = endMarker;
    if (dataEnd > dataStart && bytes[dataEnd - 1] == 0x0A) dataEnd -= 1;
    if (dataEnd > dataStart && bytes[dataEnd - 1] == 0x0D) dataEnd -= 1;
    if (dataEnd <= dataStart) continue;
    final raw = bytes.sublist(dataStart, dataEnd);
    Uint8List decoded;
    if (RegExp(r'/FlateDecode\b').hasMatch(dict)) {
      try {
        decoded = Uint8List.fromList(ZLibCodec().decode(raw));
      } catch (_) {
        continue;
      }
    } else {
      decoded = raw;
    }
    if (decoded.isEmpty || decoded.length > 10 * 1024 * 1024) continue;
    final text = latin1.decode(decoded, allowInvalid: true);
    if (text.contains('Tj') || text.contains('TJ') || text.contains('BT')) result.add(text);
  }
  return result.take(600).toList(growable: false);
}

String _extractPdfTextFromContent(String content) {
  final buffer = StringBuffer();

  for (final match in RegExp(r'\((?:\\.|[^\\)])*\)\s*Tj').allMatches(content)) {
    buffer.writeln(_decodePdfLiteral(match.group(0)!.replaceFirst(RegExp(r'\s*Tj$'), '')));
  }
  for (final match in RegExp(r'\[(.*?)\]\s*TJ', dotAll: true).allMatches(content)) {
    final arrayBody = match.group(1) ?? '';
    final line = StringBuffer();
    for (final literal in RegExp(r'\((?:\\.|[^\\)])*\)|<([0-9A-Fa-f\s]+)>').allMatches(arrayBody)) {
      final raw = literal.group(0) ?? '';
      if (raw.startsWith('(')) {
        line.write(_decodePdfLiteral(raw));
      } else if (raw.startsWith('<')) {
        line.write(_decodePdfHex(raw));
      }
    }
    final text = line.toString().trim();
    if (text.isNotEmpty) buffer.writeln(text);
  }
  for (final match in RegExp(r'''\((?:\\.|[^\\)])*\)\s*['"]''').allMatches(content)) {
    final raw = match.group(0) ?? '';
    final literal = raw.substring(0, raw.lastIndexOf(')') + 1);
    buffer.writeln(_decodePdfLiteral(literal));
  }
  for (final match in RegExp(r'<([0-9A-Fa-f\s]+)>\s*Tj').allMatches(content)) {
    buffer.writeln(_decodePdfHex(match.group(0)!.replaceFirst(RegExp(r'\s*Tj$'), '')));
  }

  return buffer.toString();
}

String _decodePdfLiteral(String raw) {
  if (raw.length >= 2 && raw.startsWith('(') && raw.endsWith(')')) {
    raw = raw.substring(1, raw.length - 1);
  }
  final out = StringBuffer();
  for (var i = 0; i < raw.length; i++) {
    final ch = raw[i];
    if (ch != '\\' || i + 1 >= raw.length) {
      out.write(ch);
      continue;
    }
    final next = raw[++i];
    switch (next) {
      case 'n':
        out.write('\n');
        break;
      case 'r':
        out.write('\n');
        break;
      case 't':
        out.write('\t');
        break;
      case 'b':
      case 'f':
        break;
      case '(':
      case ')':
      case '\\':
        out.write(next);
        break;
      case '\n':
      case '\r':
        break;
      default:
        if (RegExp(r'[0-7]').hasMatch(next)) {
          var octal = next;
          while (i + 1 < raw.length && octal.length < 3 && RegExp(r'[0-7]').hasMatch(raw[i + 1])) {
            octal += raw[++i];
          }
          final value = int.tryParse(octal, radix: 8);
          if (value != null) out.writeCharCode(value);
        } else {
          out.write(next);
        }
    }
  }
  return out.toString();
}

String _decodePdfHex(String raw) {
  var hex = raw.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
  if (hex.length.isOdd) hex += '0';
  final bytes = <int>[];
  for (var i = 0; i + 1 < hex.length; i += 2) {
    final value = int.tryParse(hex.substring(i, i + 2), radix: 16);
    if (value != null) bytes.add(value);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    final codes = <int>[];
    for (var i = 2; i + 1 < bytes.length; i += 2) {
      codes.add((bytes[i] << 8) | bytes[i + 1]);
    }
    return String.fromCharCodes(codes);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    final codes = <int>[];
    for (var i = 2; i + 1 < bytes.length; i += 2) {
      codes.add(bytes[i] | (bytes[i + 1] << 8));
    }
    return String.fromCharCodes(codes);
  }
  return latin1.decode(bytes, allowInvalid: true).replaceAll('\x00', '');
}

String _normalizeExtractedPdfText(String text) {
  final lines = _normalizeText(text)
      .replaceAll('\x00', '')
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'[ \t\u00A0]+'), ' ').trim())
      .where((line) => line.length >= 2)
      .toList(growable: false);
  final deduped = <String>[];
  String? previous;
  for (final line in lines) {
    if (line == previous) continue;
    previous = line;
    deduped.add(line);
  }
  return deduped.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}

class _TextLine {
  const _TextLine({required this.text, required this.startChar, required this.endChar});

  final String text;
  final int startChar;
  final int endChar;
}

class _TextAnchorLocator {
  const _TextAnchorLocator({
    required this.anchorChar,
    required this.totalChars,
    required this.lineIndex,
    required this.lineCount,
    this.scrollOffset,
    this.maxScrollExtent,
    this.viewportWidth,
  });

  final int anchorChar;
  final int totalChars;
  final int lineIndex;
  final int lineCount;
  final double? scrollOffset;
  final double? maxScrollExtent;
  final double? viewportWidth;

  double get progressPercent {
    if (totalChars <= 0) return 0;
    return ((anchorChar / totalChars) * 100).clamp(0.0, 100.0).toDouble();
  }

  String toJsonString({String type = 'txt-line-anchor-v1'}) => jsonEncode({
    'type': type,
    'anchorChar': anchorChar,
    'totalChars': totalChars,
    'lineIndex': lineIndex,
    'lineCount': lineCount,
    if (scrollOffset != null) 'scrollOffset': scrollOffset,
    if (maxScrollExtent != null) 'maxScrollExtent': maxScrollExtent,
    if (viewportWidth != null) 'viewportWidth': viewportWidth,
    'progressPercent': progressPercent,
    'updatedAt': DateTime.now().toUtc().toIso8601String(),
  });
}

int _lineIndexForChar(List<_TextLine> lines, int charIndex) {
  if (lines.isEmpty) return 0;
  var low = 0;
  var high = lines.length - 1;
  while (low <= high) {
    final mid = low + ((high - low) >> 1);
    final line = lines[mid];
    if (charIndex < line.startChar) {
      high = mid - 1;
    } else if (charIndex >= line.endChar) {
      low = mid + 1;
    } else {
      return mid;
    }
  }
  return low.clamp(0, lines.length - 1).toInt();
}

List<_TextLine> _buildDisplayLines(String text, double usableWidth) {
  final normalized = _normalizeText(text);
  if (normalized.isEmpty) return const [];
  final averageCharWidth = _fontWidthEstimate(_TxtReaderScreenState._fontSize);
  final maxCharsPerLine = (usableWidth / averageCharWidth).floor().clamp(24, 140).toInt();
  final result = <_TextLine>[];
  var globalStart = 0;
  final sourceLines = normalized.split('\n');
  for (var sourceIndex = 0; sourceIndex < sourceLines.length; sourceIndex++) {
    final sourceLine = sourceLines[sourceIndex];
    if (sourceLine.isEmpty) {
      result.add(_TextLine(text: '', startChar: globalStart, endChar: globalStart));
      globalStart += sourceIndex == sourceLines.length - 1 ? 0 : 1;
      continue;
    }

    var localStart = 0;
    while (localStart < sourceLine.length) {
      var localEnd = (localStart + maxCharsPerLine).clamp(localStart + 1, sourceLine.length).toInt();
      if (localEnd < sourceLine.length) {
        final window = sourceLine.substring(localStart, localEnd);
        final splitAt = window.lastIndexOf(RegExp(r'[ \t\u00A0]'));
        final minUseful = (maxCharsPerLine * 0.55).round();
        if (splitAt > minUseful) {
          localEnd = localStart + splitAt + 1;
        }
      }
      final display = sourceLine.substring(localStart, localEnd).trimRight();
      result.add(_TextLine(text: display, startChar: globalStart + localStart, endChar: globalStart + localEnd));
      localStart = localEnd;
      while (localStart < sourceLine.length && sourceLine.codeUnitAt(localStart) == 0x20) {
        localStart += 1;
      }
    }
    globalStart += sourceLine.length;
    if (sourceIndex != sourceLines.length - 1) globalStart += 1;
  }
  return result;
}

double _fontWidthEstimate(double fontSize) => fontSize * 0.56;

String _decodeTextFile(List<int> bytes) {
  if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return _decodeWindows1251(bytes);
  }
}

String _normalizeText(String text) => text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

String _safeUnsupportedBinaryPreview(String formatLabel) {
  return '$formatLabel-файл сохранён и синхронизируется как оригинал. Чтобы не показывать бинарные “кракозябры”, ReadArc не открывает этот формат как сырой текст. Для полноценного просмотра нужен нативный адаптер/конвертер формата.';
}

String _extractChmText(Uint8List bytes) {
  // CHM is an ITSF container; most real books/help files store topics compressed
  // with LZX. A naive binary string scan produces readable-looking mojibake, so
  // this adapter only shows high-confidence HTML/TOC fragments. Otherwise it
  // deliberately falls back to a clear message instead of “кракозябры”.
  final candidates = <String>[];

  void addCandidate(String text) {
    final normalized = _normalizeText(text)
        .replaceAll('\x00', '')
        .split('\n')
        .map((line) => line.replaceAll(RegExp(r'[ \t\u00A0]+'), ' ').trim())
        .where(_looksReadableChmLine)
        .toList(growable: false);
    candidates.addAll(normalized);
  }

  final cp1251 = _decodeWindows1251(bytes);
  final utf8Text = utf8.decode(bytes, allowMalformed: true);
  final utf16Text = _extractUtf16LeRuns(bytes, minLength: 8);

  for (final source in [cp1251, utf8Text, utf16Text]) {
    for (final html in RegExp(
      r'<(?:html|body|h[1-6]|p|li|ul|ol|table|tr|td|object)\b[^>]*>.*?(?:</(?:html|body|h[1-6]|p|li|ul|ol|table|tr|td|object)>|$)',
      caseSensitive: false,
      dotAll: true,
    ).allMatches(source)) {
      final text = _htmlToPlainText(html.group(0) ?? '');
      addCandidate(text);
    }

    // TOC/index files in CHM often contain plain visible titles near Local/Name
    // fields. Extract only such labeled snippets; do not scan arbitrary binary.
    for (final match in RegExp(
      r'(?:Name|Local|Title)\s*[:=]?\s*([^\n\r<>]{8,180})',
      caseSensitive: false,
    ).allMatches(source)) {
      addCandidate(match.group(1) ?? '');
    }
  }

  final deduped = <String>[];
  final seen = <String>{};
  for (final line in candidates) {
    final key = line.toLowerCase();
    if (seen.add(key)) deduped.add(line);
  }

  final preview = deduped.take(4000).join('\n');
  if (!_looksLikeReadableDocumentPreview(preview, minLetters: 80, minWords: 18)) {
    return 'CHM-файл сохранён и синхронизируется как оригинал. Внутренний CHM-контент обычно сжат в ITSF/LZX; без нативного CHM-адаптера безопасно извлечь главы не удалось. Чтобы не показывать “кракозябры”, ReadArc отображает это сообщение вместо бинарного мусора.';
  }

  return preview;
}

Future<String> _extractChmPreviewFromFile(File sourceFile) async {
  try {
    final length = await sourceFile.length();
    final maxBytes = length.clamp(0, 3 * 1024 * 1024).toInt();
    final raf = await sourceFile.open();
    try {
      final bytes = await raf.read(maxBytes);
      return _extractChmText(Uint8List.fromList(bytes));
    } finally {
      await raf.close();
    }
  } catch (_) {
    return _safeUnsupportedBinaryPreview('CHM');
  }
}

Future<_Fb2Document> _parseChmDocumentFromFile(File sourceFile) async {
  try {
    final extracted = await _tryExtractChmWithNativeTools(sourceFile);
    if (extracted.isNotEmpty) {
      final doc = _parseExtractedHtmlDocument(extracted, formatLabel: 'CHM');
      if (doc.blocks.length > 1 || (doc.blocks.isNotEmpty && doc.blocks.first.plainText.length > 120)) {
        return doc;
      }
    }

    final preview = await _extractChmPreviewFromFile(sourceFile);
    final blocks = preview
        .split(RegExp(r'\n{2,}'))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .map((part) => _Fb2Block.paragraph([_Fb2Inline(part)]))
        .toList(growable: false);
    return _makeFb2Document(
      blocks.isEmpty
          ? [
              _Fb2Block.paragraph([_Fb2Inline(_safeUnsupportedBinaryPreview('CHM'))]),
            ]
          : blocks,
    );
  } catch (error, stackTrace) {
    debugPrint('CHM adapter failure: $error\n$stackTrace');
    return _formatAdapterFailureDocument('CHM', 'CHM-адаптер завершился ошибкой: $error');
  }
}

Future<List<File>> _tryExtractChmWithNativeTools(File sourceFile) async {
  if (!(Platform.isMacOS || Platform.isLinux || Platform.isWindows)) return const [];
  Directory? tempDir;
  try {
    tempDir = await Directory.systemTemp.createTemp('readarc_chm_');
    final attempts = <Future<ProcessResult> Function()>[
      () => _runNativeTool('extract_chmLib', [sourceFile.path, tempDir!.path], timeout: const Duration(seconds: 30)),
      () => _runNativeTool('7z', [
        'x',
        '-y',
        '-o${tempDir!.path}',
        sourceFile.path,
      ], timeout: const Duration(seconds: 30)),
      () => _runNativeTool('7zz', [
        'x',
        '-y',
        '-o${tempDir!.path}',
        sourceFile.path,
      ], timeout: const Duration(seconds: 30)),
      () => _runNativeTool('unar', [
        '-quiet',
        '-o',
        tempDir!.path,
        sourceFile.path,
      ], timeout: const Duration(seconds: 30)),
    ];
    for (final attempt in attempts) {
      try {
        final result = await attempt();
        if (result.exitCode == 0) {
          final files = await _collectReadableDocumentFiles(tempDir);
          if (files.isNotEmpty) return files;
        }
      } catch (_) {}
    }
  } catch (_) {}
  return const [];
}

Future<_Fb2Document> _parseDjvuDocumentFromFile(File sourceFile) async {
  final pageCount = await _readDjvuPageCount(sourceFile) ?? 0;
  return _makeFb2Document([
    const _Fb2Block.title('DJVU'),
    _Fb2Block.paragraph([
      _Fb2Inline(
        'DJVU-файл распознан встроенным ReadArc probe. Страниц: ${pageCount <= 0 ? 'не определено' : pageCount}. Внешние DjVuLibre/ddjvu/djvused больше не используются. Полный рендер страниц переводится на встроенный djvu-rs engine.',
      ),
    ]),
  ]);
}

Future<_Fb2Document?> _tryExtractDjvuText(File sourceFile) async {
  // No shell tools in production. Text extraction will be provided by the same
  // embedded djvu-rs engine as page rendering.
  return null;
}

Future<int?> _readDjvuPageCount(File sourceFile) async {
  try {
    final length = await sourceFile.length();
    final limit = length < 16 * 1024 * 1024 ? length : 16 * 1024 * 1024;
    final bytes = await sourceFile.openRead(0, limit).fold<BytesBuilder>(BytesBuilder(copy: false), (builder, chunk) {
      builder.add(chunk);
      return builder;
    });
    final probe = DjvuEmbeddedProbe.inspect(bytes.takeBytes());
    if (probe.isDjvu && probe.pageCount > 0) return probe.pageCount;
  } catch (error) {
    debugPrint('Embedded DJVU probe failed: $error');
  }
  return null;
}

Future<String> _resolveNativeTool(String executable) async {
  if (executable.contains(Platform.pathSeparator)) return executable;
  final candidates = <String>[
    executable,
    if (Platform.isMacOS) '/opt/homebrew/bin/$executable',
    if (Platform.isMacOS) '/usr/local/bin/$executable',
    if (Platform.isMacOS) '/opt/local/bin/$executable',
    if (!Platform.isWindows) '/usr/bin/$executable',
    if (!Platform.isWindows) '/bin/$executable',
  ];
  for (final candidate in candidates.skip(1)) {
    try {
      final file = File(candidate);
      if (await file.exists()) return candidate;
    } catch (_) {}
  }
  return executable;
}

Future<ProcessResult> _runNativeTool(
  String executable,
  List<String> arguments, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  Process? process;
  final stdout = <int>[];
  final stderr = <int>[];
  try {
    final resolvedExecutable = await _resolveNativeTool(executable);
    process = await Process.start(resolvedExecutable, arguments, runInShell: Platform.isWindows);
    final stdoutDone = process.stdout.listen(stdout.addAll).asFuture<void>();
    final stderrDone = process.stderr.listen(stderr.addAll).asFuture<void>();
    final exitCode = await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        process?.kill(ProcessSignal.sigkill);
        throw TimeoutException('Native tool timeout: $executable', timeout);
      },
    );
    await Future.wait([stdoutDone, stderrDone]).timeout(const Duration(seconds: 2), onTimeout: () => const []);
    return ProcessResult(
      process.pid,
      exitCode,
      utf8.decode(stdout, allowMalformed: true),
      utf8.decode(stderr, allowMalformed: true),
    );
  } on TimeoutException {
    try {
      process?.kill(ProcessSignal.sigkill);
    } catch (_) {}
    rethrow;
  }
}

Future<List<File>> _collectReadableDocumentFiles(Directory root) async {
  final files = <File>[];
  if (!await root.exists()) return files;
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final lower = entity.path.toLowerCase();
    if (lower.endsWith('.html') ||
        lower.endsWith('.htm') ||
        lower.endsWith('.xhtml') ||
        lower.endsWith('.hhc') ||
        lower.endsWith('.hhk')) {
      files.add(entity);
    }
  }
  files.sort((a, b) {
    final an = a.uri.pathSegments.isEmpty ? a.path.toLowerCase() : a.uri.pathSegments.last.toLowerCase();
    final bn = b.uri.pathSegments.isEmpty ? b.path.toLowerCase() : b.uri.pathSegments.last.toLowerCase();
    int rank(String name) {
      if (name.contains('index') || name.contains('default') || name.endsWith('.hhc')) return 0;
      if (name.contains('toc') || name.contains('contents')) return 1;
      return 2;
    }

    final r = rank(an).compareTo(rank(bn));
    return r != 0 ? r : an.compareTo(bn);
  });
  return files.take(80).toList(growable: false);
}

_Fb2Document _parseExtractedHtmlDocument(List<File> files, {required String formatLabel}) {
  final blocks = <_Fb2Block>[];
  var blockBudget = 1800;
  var imageBudgetBytes = 24 * 1024 * 1024;
  for (final file in files.take(80)) {
    if (blockBudget <= 0) break;
    Uint8List fileBytes;
    try {
      if (file.lengthSync() > 8 * 1024 * 1024) continue;
      fileBytes = file.readAsBytesSync();
    } catch (_) {
      continue;
    }
    final html = _decodeTextFile(fileBytes);
    final title = _htmlTitle(html) ?? file.uri.pathSegments.last;
    final clean = html
        .replaceAll(RegExp(r'<script\b[^>]*>.*?</script>', caseSensitive: false, dotAll: true), ' ')
        .replaceAll(RegExp(r'<style\b[^>]*>.*?</style>', caseSensitive: false, dotAll: true), ' ');
    if (title.trim().isNotEmpty) blocks.add(_Fb2Block.title(_decodeXmlEntities(title).trim()));
    for (final img in RegExp(
      r'''<img\b[^>]*\bsrc\s*=\s*['"]([^'"]+)['"][^>]*>''',
      caseSensitive: false,
    ).allMatches(clean)) {
      final image = _readImageNearHtml(file, img.group(1) ?? '');
      if (image != null && imageBudgetBytes > 0) {
        imageBudgetBytes -= image.length;
        blocks.add(_Fb2Block.image(image));
      }
    }
    final blockRe = RegExp(
      r'<h[1-6]\b[^>]*>.*?</h[1-6]>|<p\b[^>]*>.*?</p>|<li\b[^>]*>.*?</li>|<tr\b[^>]*>.*?</tr>|<div\b[^>]*>.*?</div>',
      caseSensitive: false,
      dotAll: true,
    );
    var found = false;
    for (final match in blockRe.allMatches(clean)) {
      final raw = match.group(0) ?? '';
      final text = _htmlToPlainText(raw).replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isEmpty || text.length < 2) continue;
      found = true;
      if (blockBudget-- <= 0) break;
      if (raw.startsWith(RegExp(r'<h[1-6]', caseSensitive: false))) {
        blocks.add(_Fb2Block.title(text));
      } else if (raw.startsWith(RegExp(r'<li', caseSensitive: false))) {
        blocks.add(_Fb2Block.paragraph([_Fb2Inline('• $text')]));
      } else {
        blocks.add(_Fb2Block.paragraph(_parseHtmlInlines(raw, file.path)));
      }
    }
    if (!found) {
      final text = _htmlToPlainText(clean).replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isNotEmpty) blocks.add(_Fb2Block.paragraph([_Fb2Inline(text)]));
    }
  }
  if (blocks.isEmpty) {
    return _makeFb2Document([
      _Fb2Block.paragraph([_Fb2Inline('Не удалось извлечь HTML-главы из $formatLabel.')]),
    ]);
  }
  return _makeFb2Document(blocks);
}

String? _htmlTitle(String html) {
  final title = RegExp(r'<title\b[^>]*>(.*?)</title>', caseSensitive: false, dotAll: true).firstMatch(html)?.group(1);
  if (title != null && title.trim().isNotEmpty) return _htmlToPlainText(title).trim();
  final heading = RegExp(r'<h1\b[^>]*>(.*?)</h1>', caseSensitive: false, dotAll: true).firstMatch(html)?.group(1);
  if (heading != null && heading.trim().isNotEmpty) return _htmlToPlainText(heading).trim();
  return null;
}

Uint8List? _readImageNearHtml(File htmlFile, String srcRaw) {
  var src = _decodeXmlEntities(srcRaw).trim();
  if (src.isEmpty || src.startsWith('http://') || src.startsWith('https://') || src.startsWith('data:')) return null;
  final hash = src.indexOf('#');
  if (hash >= 0) src = src.substring(0, hash);
  final query = src.indexOf('?');
  if (query >= 0) src = src.substring(0, query);
  try {
    src = Uri.decodeFull(src);
  } catch (_) {}
  final base = htmlFile.parent.uri;
  final resolved = base.resolve(src).toFilePath();
  final file = File(resolved);
  try {
    if (file.existsSync() && file.lengthSync() <= 6 * 1024 * 1024) return file.readAsBytesSync();
  } catch (_) {}
  return null;
}

bool _looksLikeReadableDocumentPreview(String text, {required int minLetters, required int minWords}) {
  final normalized = text.trim();
  if (normalized.length < 80) return false;
  final letters = RegExp(r'[A-Za-zА-Яа-яЁё]').allMatches(normalized).length;
  final words = RegExp(r'[A-Za-zА-Яа-яЁё]{2,}').allMatches(normalized).length;
  final replacement = '�'.allMatches(normalized).length;
  final controls = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]').allMatches(normalized).length;
  final suspicious = RegExp(r'[þÿÐðªº§¤¦¶]').allMatches(normalized).length;
  final len = normalized.length;
  if (letters < minLetters || words < minWords) return false;
  if (replacement > 0 || controls > 0) return false;
  if (suspicious / len > 0.015) return false;
  if (letters / len < 0.45) return false;
  return true;
}

String _extractSingleByteRuns(Uint8List bytes, {required int minLength}) {
  final lines = <String>[];
  final current = <int>[];
  void flush() {
    if (current.length >= minLength) {
      final decoded = _decodeWindows1251(current);
      lines.add(decoded);
    }
    current.clear();
  }

  for (final byte in bytes) {
    final printable = byte == 0x09 || byte == 0x0A || byte == 0x0D || (byte >= 0x20 && byte <= 0x7E) || byte >= 0x80;
    if (printable) {
      current.add(byte);
    } else {
      flush();
    }
  }
  flush();
  return lines.join('\n');
}

String _extractUtf16LeRuns(Uint8List bytes, {required int minLength}) {
  final lines = <String>[];
  final codes = <int>[];

  bool allowed(int code) =>
      code == 0x09 ||
      code == 0x0A ||
      code == 0x0D ||
      (code >= 0x20 && code <= 0x7E) ||
      (code >= 0x0400 && code <= 0x052F) ||
      code == 0x00A0 ||
      code == 0x00AB ||
      code == 0x00BB ||
      code == 0x2013 ||
      code == 0x2014 ||
      code == 0x2026 ||
      code == 0x2116;

  void flush() {
    if (codes.length >= minLength) lines.add(String.fromCharCodes(codes));
    codes.clear();
  }

  for (var i = 0; i + 1 < bytes.length; i += 2) {
    final code = bytes[i] | (bytes[i + 1] << 8);
    if (allowed(code)) {
      codes.add(code);
    } else {
      flush();
    }
  }
  flush();
  return lines.join('\n');
}

bool _looksReadableChmLine(String line) {
  final text = line.trim();
  if (text.length < 8 || text.length > 360) return false;
  if (RegExp(r'^[\W_\d]+$').hasMatch(text)) return false;
  if (RegExp(r'(?:[A-Za-z]:\\|/)[^ ]{20,}').hasMatch(text)) return false;
  final letters = RegExp(r'[A-Za-zА-Яа-яЁё]').allMatches(text).length;
  final bad = RegExp(r'[�\x00-\x08\x0B\x0C\x0E-\x1F]').allMatches(text).length;
  final symbols = RegExp(r'''[^A-Za-zА-Яа-яЁё0-9 .,;:!?()\[\]{}<>«»"'\-–—/\n\t]''').allMatches(text).length;
  final len = text.length;
  if (letters / len < 0.35) return false;
  if (bad / len > 0.02) return false;
  if (symbols / len > 0.14) return false;
  return true;
}

Uint8List _archiveFileBytes(ArchiveFile file) {
  final content = file.content;
  if (content is Uint8List) return content;
  if (content is List<int>) return Uint8List.fromList(content);
  throw StateError('Не удалось прочитать файл EPUB: ${file.name}');
}

String? _xmlAttr(String tag, String name) {
  final match = RegExp("$name\\s*=\\s*[\"']([^\"']+)[\"']", caseSensitive: false).firstMatch(tag);
  return match?.group(1);
}

String _zipDirName(String path) {
  final normalized = path.replaceAll('\\', '/');
  final index = normalized.lastIndexOf('/');
  return index <= 0 ? '' : normalized.substring(0, index);
}

String _joinZipPath(String baseDir, String href) {
  final parts = <String>[];
  final cleanedHref = href.trim().replaceAll('\\', '/');
  final joined = cleanedHref.startsWith('/') || baseDir.isEmpty
      ? cleanedHref.replaceFirst(RegExp(r'^/+'), '')
      : '$baseDir/$cleanedHref';
  final raw = joined.split('/');
  for (final part in raw) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isNotEmpty) parts.removeLast();
    } else {
      try {
        parts.add(Uri.decodeFull(part));
      } catch (_) {
        parts.add(part);
      }
    }
  }
  return parts.join('/');
}

String _htmlToPlainText(String html) {
  var text = html;
  text = text.replaceAll(RegExp(r'<script\b[^>]*>.*?</script>', caseSensitive: false, dotAll: true), '');
  text = text.replaceAll(RegExp(r'<style\b[^>]*>.*?</style>', caseSensitive: false, dotAll: true), '');
  text = text.replaceAll(RegExp(r'</(p|div|section|article|chapter|h[1-6]|li|tr)>', caseSensitive: false), '\n');
  text = text.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  text = text.replaceAll(RegExp(r'<[^>]+>'), ' ');
  return _decodeXmlEntities(text).replaceAll(RegExp(r'[ \t\u00a0]+'), ' ').replaceAll(RegExp(r'\n\s+'), '\n');
}

String _extractFb2Text(String xmlText) {
  var text = _normalizeText(xmlText);
  text = text.replaceAll(RegExp(r'<\?xml[^>]*>', caseSensitive: false), '');
  text = text.replaceAll(RegExp(r'<binary\b[^>]*>.*?</binary>', caseSensitive: false, dotAll: true), '');
  text = text.replaceAll(RegExp(r'<description\b[^>]*>.*?</description>', caseSensitive: false, dotAll: true), '');
  text = text.replaceAll(RegExp(r'<empty-line\s*/?>', caseSensitive: false), '\n\n');
  text = text.replaceAll(RegExp(r'</(p|v|subtitle|title|section|poem|stanza)>', caseSensitive: false), '\n');
  text = text.replaceAll(RegExp(r'<(p|v|subtitle|title)\b[^>]*>', caseSensitive: false), '');
  text = text.replaceAll(RegExp(r'<[^>]+>', dotAll: true), '');
  text = _decodeXmlEntities(text);
  text = text.split('\n').map((line) => line.replaceAll(RegExp(r'[ \t\u00A0]+'), ' ').trimRight()).join('\n');
  text = text.replaceAll(RegExp(r'\n{4,}'), '\n\n\n').trim();
  return text.isEmpty ? 'Не удалось извлечь текст из FB2.' : text;
}

String _decodeXmlEntities(String text) {
  return text.replaceAllMapped(RegExp(r'&(#x?[0-9a-fA-F]+|[a-zA-Z]+);'), (match) {
    final entity = match.group(1)!;
    switch (entity) {
      case 'amp':
        return '&';
      case 'lt':
        return '<';
      case 'gt':
        return '>';
      case 'quot':
        return '"';
      case 'apos':
        return "'";
      case 'nbsp':
        return ' ';
    }
    if (entity.startsWith('#x') || entity.startsWith('#X')) {
      final value = int.tryParse(entity.substring(2), radix: 16);
      return value == null ? match.group(0)! : String.fromCharCode(value);
    }
    if (entity.startsWith('#')) {
      final value = int.tryParse(entity.substring(1));
      return value == null ? match.group(0)! : String.fromCharCode(value);
    }
    return match.group(0)!;
  });
}

String _decodeWindows1251(List<int> bytes) {
  const table = <int>[
    0x0402,
    0x0403,
    0x201A,
    0x0453,
    0x201E,
    0x2026,
    0x2020,
    0x2021,
    0x20AC,
    0x2030,
    0x0409,
    0x2039,
    0x040A,
    0x040C,
    0x040B,
    0x040F,
    0x0452,
    0x2018,
    0x2019,
    0x201C,
    0x201D,
    0x2022,
    0x2013,
    0x2014,
    0x0000,
    0x2122,
    0x0459,
    0x203A,
    0x045A,
    0x045C,
    0x045B,
    0x045F,
    0x00A0,
    0x040E,
    0x045E,
    0x0408,
    0x00A4,
    0x0490,
    0x00A6,
    0x00A7,
    0x0401,
    0x00A9,
    0x0404,
    0x00AB,
    0x00AC,
    0x00AD,
    0x00AE,
    0x0407,
    0x00B0,
    0x00B1,
    0x0406,
    0x0456,
    0x0491,
    0x00B5,
    0x00B6,
    0x00B7,
    0x0451,
    0x2116,
    0x0454,
    0x00BB,
    0x0458,
    0x0405,
    0x0455,
    0x0457,
    0x0410,
    0x0411,
    0x0412,
    0x0413,
    0x0414,
    0x0415,
    0x0416,
    0x0417,
    0x0418,
    0x0419,
    0x041A,
    0x041B,
    0x041C,
    0x041D,
    0x041E,
    0x041F,
    0x0420,
    0x0421,
    0x0422,
    0x0423,
    0x0424,
    0x0425,
    0x0426,
    0x0427,
    0x0428,
    0x0429,
    0x042A,
    0x042B,
    0x042C,
    0x042D,
    0x042E,
    0x042F,
    0x0430,
    0x0431,
    0x0432,
    0x0433,
    0x0434,
    0x0435,
    0x0436,
    0x0437,
    0x0438,
    0x0439,
    0x043A,
    0x043B,
    0x043C,
    0x043D,
    0x043E,
    0x043F,
    0x0440,
    0x0441,
    0x0442,
    0x0443,
    0x0444,
    0x0445,
    0x0446,
    0x0447,
    0x0448,
    0x0449,
    0x044A,
    0x044B,
    0x044C,
    0x044D,
    0x044E,
    0x044F,
  ];

  final buffer = StringBuffer();
  for (final byte in bytes) {
    if (byte < 0x80) {
      buffer.writeCharCode(byte);
    } else {
      final codePoint = table[byte - 0x80];
      buffer.writeCharCode(codePoint == 0 ? 0xFFFD : codePoint);
    }
  }
  return buffer.toString();
}

class _UnsupportedReaderPlaceholder extends StatelessWidget {
  const _UnsupportedReaderPlaceholder({required this.book});

  final BookRecord book;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.extension_rounded, size: 56),
            const SizedBox(height: 16),
            Text(
              'Формат ${book.format.toUpperCase()} добавлен в библиотеку, но полноценный renderer ещё не подключён.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            const Text(
              'Production-версия должна подключить встроенные Readium/PDFium/DJVU/CHM/DOCX engines и сохранять locator для каждого формата.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

String _formatLocalDateTimeSeconds(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key, required this.storage, required this.sync});

  final StorageService storage;
  final SyncService sync;

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  final _accountController = TextEditingController();
  final _deviceNameController = TextEditingController();
  final _pairingInputController = TextEditingController();
  LibraryManifest? _manifest;
  SyncSettings? _settings;
  bool _busy = false;
  bool _pairingBusy = false;
  bool _logExpanded = false;
  PairingInvite? _pairingInvite;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _accountController.dispose();
    _deviceNameController.dispose();
    _pairingInputController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final manifest = await widget.storage.loadManifest();
    final settings = (await widget.storage.loadSyncSettings()).asOfficial(autoConnect: true);
    await widget.storage.saveSyncSettings(settings);
    if (!mounted) return;
    _manifest = manifest;
    _settings = settings;
    _accountController.text = manifest.accountId;
    _deviceNameController.text = manifest.deviceName;
    setState(() {});
  }

  SyncSettings _settingsFromForm({bool? autoConnect}) =>
      SyncSettings(autoConnect: autoConnect ?? true).asOfficial(autoConnect: true);

  Future<void> _editDeviceName() async {
    final controller = TextEditingController(text: _deviceNameController.text.trim());
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Название устройства'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            labelText: 'Название устройства',
            helperText: 'Это имя будет видно другим доверенным устройствам.',
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text('Сохранить')),
        ],
      ),
    );
    controller.dispose();
    final normalized = value?.trim() ?? '';
    if (normalized.isEmpty || normalized == _deviceNameController.text.trim()) return;
    setState(() => _busy = true);
    try {
      final manifest = await widget.storage.changeDeviceName(normalized);
      await widget.sync.broadcastLibrarySnapshot(reason: 'device_name_changed');
      if (!mounted) return;
      _deviceNameController.text = manifest.deviceName;
      setState(() => _manifest = manifest);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Название устройства сохранено')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Не удалось изменить название устройства: $error')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editAccountId() async {
    final controller = TextEditingController(text: _accountController.text.trim());
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Аккаунт'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            labelText: 'Аккаунт',
            helperText: 'Обычно менять не нужно. Используйте только для восстановления/переноса аккаунта вручную.',
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text('Сохранить')),
        ],
      ),
    );
    controller.dispose();
    final normalized = value?.trim() ?? '';
    if (normalized.isEmpty || normalized == _accountController.text.trim()) return;
    setState(() => _busy = true);
    try {
      await widget.sync.disconnect();
      final manifest = await widget.storage.changeAccountId(normalized);
      if (!mounted) return;
      _accountController.text = manifest.accountId;
      setState(() => _manifest = manifest);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Аккаунт сохранён')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось изменить аккаунт: $error')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createPairingInvite() async {
    setState(() => _pairingBusy = true);
    try {
      final settings = _settingsFromForm(autoConnect: true);
      await widget.storage.saveSyncSettings(settings);
      final invite = await widget.sync.createPairingInvite(settings: settings);
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _pairingInvite = invite;
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Код подключения создан')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось создать код: $error')));
    } finally {
      if (mounted) setState(() => _pairingBusy = false);
    }
  }

  Future<PairingInvite?> _ensurePairingInvite({bool forceFresh = false}) async {
    final existing = _pairingInvite;
    if (!forceFresh && existing != null && !existing.isNearExpiry) return existing;
    setState(() => _pairingBusy = true);
    try {
      final settings = _settingsFromForm(autoConnect: true);
      await widget.storage.saveSyncSettings(settings);
      final invite = await widget.sync.createPairingInvite(settings: settings);
      if (!mounted) return invite;
      setState(() {
        _settings = settings;
        _pairingInvite = invite;
      });
      return invite;
    } catch (error) {
      if (!mounted) return null;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось создать QR-код: $error')));
      return null;
    } finally {
      if (mounted) setState(() => _pairingBusy = false);
    }
  }

  Future<void> _showPairingQrCode() async {
    final invite = await _ensurePairingInvite(forceFresh: true);
    if (!mounted || invite == null) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('QR-код подключения'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QrImageView(data: invite.code, version: QrVersions.auto, size: 260, backgroundColor: Colors.white),
            const SizedBox(height: 12),
            Text('Код: ${invite.displayCode}'),
            const SizedBox(height: 4),
            Text(
              'Действует до: ${_formatLocalDateTimeSeconds(invite.expiresAt)}',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              'Отсканируйте QR на подключаемом устройстве.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Закрыть'))],
      ),
    );
  }

  String _pairingCodeFromScannedValue(String scanned) {
    final raw = scanned.trim();
    if (raw.startsWith('readarc://')) {
      final uri = Uri.tryParse(raw);
      final code = uri == null ? '' : (uri.queryParameters['code'] ?? '');
      final digits = code.replaceAll(RegExp(r'[^0-9]'), '');
      if (digits.length == 6) return digits;
    }
    final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    return digits.length >= 6 ? digits.substring(0, 6) : digits;
  }

  Future<void> _scanPairingQrCode() async {
    if (!(Platform.isAndroid || Platform.isIOS)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Сканирование QR-кода доступно на мобильных устройствах.')));
      return;
    }
    final scanned = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const _PairingQrScannerScreen()));
    if (scanned == null || scanned.trim().isEmpty || !mounted) return;
    _pairingInputController.text = _pairingCodeFromScannedValue(scanned);
    await _claimPairingInvite();
  }

  Future<void> _claimPairingInvite() async {
    setState(() => _pairingBusy = true);
    try {
      final settings = _settingsFromForm(autoConnect: true);
      final result = await widget.sync.claimPairingInvite(
        input: _pairingInputController.text,
        fallbackSettings: settings,
      );
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Подключено к аккаунту ${result.ownerDeviceName}')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось подключиться по коду: $error')));
    } finally {
      if (mounted) setState(() => _pairingBusy = false);
    }
  }

  Future<void> _copyAccountId() async {
    await Clipboard.setData(ClipboardData(text: _accountController.text.trim()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Аккаунт скопирован')));
  }

  Future<void> _revokeTrustedDevice(TrustedDeviceRecord device) async {
    final manifest = _manifest;
    if (manifest == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Отозвать доступ?'),
        content: Text(
          'Устройство «${device.name}» потеряет право участвовать в синхронизации этого аккаунта. Его события и передачи файлов будут отклоняться другими устройствами.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Отозвать доступ')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final updated = await widget.storage.revokeTrustedDevice(device.deviceId);
      await widget.sync.broadcastLibrarySnapshot(reason: 'trusted_device_revoked');
      if (!mounted) return;
      setState(() => _manifest = updated);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось отозвать доступ: $error')));
    }
  }

  Future<void> _pruneTrustedDevices() async {
    try {
      final updated = await widget.storage.pruneDeletedTrustedDevices();
      if (!mounted) return;
      setState(() => _manifest = updated);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Список устройств очищен')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось очистить список: $error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final manifest = _manifest;
    if (manifest == null || _settings == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final revokedTrustedDevices = manifest.trustedDevices.where((device) => device.isRevoked).length;

    return Scaffold(
      appBar: AppBar(title: const Text('Синхронизация')),
      body: ValueListenableBuilder<SyncStateSnapshot>(
        valueListenable: widget.sync.state,
        builder: (context, syncState, _) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            children: [
              _SectionCard(
                title: 'Устройство',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            manifest.deviceName,
                            style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(width: 12),
                        FilledButton.tonalIcon(
                          onPressed: _busy ? null : _editDeviceName,
                          icon: const Icon(Icons.edit_rounded),
                          label: const Text('Редактировать'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text('Статус подключения: ${syncState.statusText}'),
                    if (manifest.isCurrentDeviceRevoked) ...[
                      const SizedBox(height: 10),
                      const Text(
                        'Доступ этого устройства отозван. Локальная библиотека остаётся доступной, но синхронизация остановлена. Для повторного подключения отсканируйте новый QR-код владельца аккаунта.',
                      ),
                    ],
                  ],
                ),
              ),
              _SectionCard(
                title: 'Подключение',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (Platform.isAndroid || Platform.isIOS) ...[
                      FilledButton.icon(
                        onPressed: _pairingBusy ? null : _scanPairingQrCode,
                        icon: const Icon(Icons.qr_code_scanner_rounded),
                        label: const Text('Сканировать QR'),
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextField(
                      controller: _pairingInputController,
                      decoration: const InputDecoration(labelText: 'Введите код приглашения'),
                      keyboardType: TextInputType.number,
                      onSubmitted: (_) {
                        if (!_pairingBusy) unawaited(_claimPairingInvite());
                      },
                    ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.icon(
                        onPressed: _pairingBusy ? null : _claimPairingInvite,
                        icon: _pairingBusy
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.login_rounded),
                        label: const Text('Подключиться по коду'),
                      ),
                    ),
                  ],
                ),
              ),
              _SectionCard(
                title: 'Другое устройство',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _pairingBusy ? null : _showPairingQrCode,
                            icon: _pairingBusy
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.qr_code_2_rounded),
                            label: const Text('Показать QR'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _pairingBusy ? null : _createPairingInvite,
                            icon: const Icon(Icons.pin_rounded),
                            label: const Text('Создать код подключения'),
                          ),
                        ),
                      ],
                    ),
                    if (_pairingInvite != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          color: Theme.of(context).colorScheme.primaryContainer,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Center(
                              child: Text(
                                _pairingInvite!.displayCode,
                                style: Theme.of(context).textTheme.displaySmall
                                    ?.copyWith(fontWeight: FontWeight.w800, letterSpacing: 6),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Center(
                              child: Text('Действует до: ${_formatLocalDateTimeSeconds(_pairingInvite!.expiresAt)}'),
                            ),
                            const SizedBox(height: 10),
                            const Center(child: Text('Введите код на подключаемом устройстве.')),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Card(
                child: ExpansionTile(
                  title: const Text('Доверенные устройства'),
                  subtitle: Text(
                    manifest.activeTrustedDevices.isEmpty
                        ? 'Пока только текущее устройство'
                        : 'Доверенных: ${manifest.activeTrustedDevices.length}${revokedTrustedDevices > 0 ? ', отозвано: $revokedTrustedDevices' : ''}',
                  ),
                  childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SelectableText('Аккаунт: ${manifest.accountId}'),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 12,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              OutlinedButton.icon(
                                onPressed: _busy ? null : _editAccountId,
                                icon: const Icon(Icons.manage_accounts_rounded),
                                label: const Text('Редактировать аккаунт'),
                              ),
                              OutlinedButton.icon(
                                onPressed: _copyAccountId,
                                icon: const Icon(Icons.copy_rounded),
                                label: const Text('Скопировать аккаунт'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          SelectableText('Идентификатор устройства: ${manifest.deviceId}'),
                          SelectableText(
                            "Ключ устройства: ${manifest.currentDeviceTrust?.effectiveFingerprint ?? 'не создан'}",
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 28),
                    if (manifest.activeTrustedDevices.isEmpty)
                      const Align(alignment: Alignment.centerLeft, child: Text('Пока только текущее устройство'))
                    else
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Доступ можно отозвать у любого другого устройства. Повторное подключение возможно по новому QR-коду владельца аккаунта.',
                          ),
                          const SizedBox(height: 8),
                          ...manifest.activeTrustedDevices.map((device) {
                            final isCurrent = device.deviceId == manifest.deviceId;
                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(isCurrent ? Icons.phone_iphone_rounded : Icons.devices_rounded),
                              title: Text('${device.name}${isCurrent ? ' • это устройство' : ''}'),
                              subtitle: Text(
                                '${device.role} • ${device.trustStatusLabel}\n'
                                'Ключ: ${device.effectiveFingerprint}\n'
                                'Права: metadata ${device.canSyncMetadata ? '✓' : '—'}, files ${device.canTransferFiles ? '✓' : '—'}',
                              ),
                              trailing: isCurrent
                                  ? null
                                  : IconButton(
                                      tooltip: 'Отозвать доступ устройства',
                                      icon: const Icon(Icons.block_rounded),
                                      onPressed: () => _revokeTrustedDevice(device),
                                    ),
                            );
                          }),
                          if (manifest.trustedDevices.any((device) => device.isRevoked)) ...[
                            const Divider(height: 24),
                            const Text('Отозванные устройства'),
                            const SizedBox(height: 8),
                            ...manifest.trustedDevices
                                .where((device) => device.isRevoked)
                                .map(
                                  (device) => ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: const Icon(Icons.block_rounded),
                                    title: Text(device.name),
                                    subtitle: Text(
                                      '${device.deviceId}\nКлюч: ${device.effectiveFingerprint}\nОтозвано: ${device.deletedAt?.toLocal() ?? ''}',
                                    ),
                                  ),
                                ),
                          ],
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: _pruneTrustedDevices,
                            icon: const Icon(Icons.cleaning_services_outlined),
                            label: const Text('Очистить старые отозванные записи'),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
              Card(
                child: ExpansionTile(
                  initiallyExpanded: _logExpanded,
                  onExpansionChanged: (value) => setState(() => _logExpanded = value),
                  title: const Text('Журнал событий'),
                  subtitle: Text(
                    syncState.logLines.isEmpty ? 'Пока нет событий' : 'Событий: ${syncState.logLines.length}',
                  ),
                  childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                  children: [
                    if (syncState.logLines.isEmpty)
                      const Align(alignment: Alignment.centerLeft, child: Text('Пока нет событий'))
                    else
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: syncState.logLines.map(Text.new).toList(),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _PairingQrScannerScreen extends StatefulWidget {
  const _PairingQrScannerScreen();

  @override
  State<_PairingQrScannerScreen> createState() => _PairingQrScannerScreenState();
}

class _PairingQrScannerScreenState extends State<_PairingQrScannerScreen> {
  final _qrKey = GlobalKey(debugLabel: 'ReadArcQrScanner');
  QRViewController? _controller;
  StreamSubscription<Barcode>? _subscription;
  bool _handled = false;

  void _onQRViewCreated(QRViewController controller) {
    _controller = controller;
    _subscription = controller.scannedDataStream.listen(
      (scan) {
        if (_handled) return;
        final value = scan.code;
        if (value == null || value.trim().isEmpty) return;
        _handled = true;
        unawaited(_subscription?.cancel());
        _subscription = null;
        unawaited(controller.pauseCamera());
        if (mounted) Navigator.of(context).pop(value.trim());
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('ReadArc QR scanner stream error: $error\n$stackTrace');
      },
    );
  }

  @override
  void reassemble() {
    super.reassemble();
    final controller = _controller;
    if (controller == null) return;
    if (Platform.isAndroid) {
      unawaited(controller.pauseCamera());
    }
    unawaited(controller.resumeCamera());
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Сканировать QR')),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                QRView(
                  key: _qrKey,
                  onQRViewCreated: _onQRViewCreated,
                  overlay: QrScannerOverlayShape(
                    borderColor: _raWarmGold,
                    borderRadius: 14,
                    borderLength: 28,
                    borderWidth: 7,
                    cutOutSize: MediaQuery.sizeOf(context).shortestSide * 0.68,
                  ),
                ),
                Positioned(
                  left: 24,
                  right: 24,
                  bottom: 24,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.48),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                      child: Text(
                        'Наведите камеру на QR-код ReadArc. После сканирования будет использован только 6-значный код подключения.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.keyboard_alt_outlined),
                label: const Text('Ввести код вручную'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}
