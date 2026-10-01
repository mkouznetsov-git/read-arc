import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readarc/app/readarc_app.dart';
import 'package:readarc/models/book.dart';
import 'package:readarc/models/manifest.dart';
import 'package:readarc/services/book_import_service.dart';
import 'package:readarc/services/library_repository.dart';
import 'package:readarc/services/library_scanner.dart';
import 'package:readarc/services/library_storage.dart';
import 'package:readarc/services/portable_library_state.dart';
import 'package:readarc/services/storage_service.dart';
import 'package:readarc/services/sync/sync_service.dart';

// UI transitions use deterministic state. Real filesystem, stream, tombstone
// and manifest-preservation behavior is tested in storage_service_test and
// library_repository_test, outside Flutter's fake async clock.
void main() {
  testWidgets('empty library can change root and add a book without restart', (tester) async {
    final fixture = await _mount(tester);
    expect(find.text('Папка: First folder'), findsOneWidget);
    await tester.tap(find.text('Сменить папку'));
    await tester.pumpAndSettle();
    expect(find.text('Папка: Second folder'), findsOneWidget);
    expect(fixture.storage.chooseCalls, 1);
    final scansBefore = fixture.storage.scanCalls;
    await tester.tap(find.widgetWithText(FilledButton, 'Добавить книгу'));
    await tester.pumpAndSettle();
    expect(fixture.importer.pickCalls, 1);
    expect(fixture.storage.scanCalls, greaterThan(scansBefore));
    expect(find.text('Imported book'), findsOneWidget);
    expect(find.text('В выбранной библиотеке пока нет книг'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('provider failure is visible and retry succeeds without raw plugin details', (tester) async {
    final fixture = await _mount(tester);
    fixture.importer.failImport = true;
    await tester.tap(find.widgetWithText(FilledButton, 'Добавить книгу'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Не удалось прочитать выбранный файл'), findsOneWidget);
    expect(find.textContaining('PlatformException'), findsNothing);
    expect(find.textContaining('NullPointerException'), findsNothing);
    expect(find.text('Папка: First folder'), findsOneWidget);
    fixture.importer.failImport = false;
    await tester.tap(find.widgetWithText(FilledButton, 'Добавить книгу'));
    await tester.pumpAndSettle();
    expect(find.text('Imported book'), findsOneWidget);
    expect(fixture.importer.pickCalls, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('platform secret errors show recovery guidance and retry without clearing state', (tester) async {
    final fixture = await _mount(tester, failSecrets: true);
    final original = fixture.storage.manifest;
    final guidance = find.textContaining('Защищённые данные этой установки недоступны');
    expect(guidance, findsOneWidget);
    expect(find.textContaining('Recovery Key'), findsOneWidget);
    expect(find.textContaining('PlatformException'), findsNothing);
    expect(find.textContaining('NullPointerException'), findsNothing);
    expect(tester.widget<FloatingActionButton>(find.byType(FloatingActionButton)).onPressed, isNull);
    final reads = fixture.storage.readCalls;
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    expect(fixture.storage.readCalls, greaterThan(reads));
    expect(guidance, findsOneWidget);
    expect(identical(fixture.storage.manifest, original), isTrue);
    fixture.storage.failSecrets = false;
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    expect(find.text('Папка: First folder'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<_Fixture> _mount(WidgetTester tester, {bool failSecrets = false}) async {
  final storage = _Storage()..failSecrets = failSecrets;
  final importer = _Importer(storage);
  final sync = SyncService(storage);
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (_) async {
    throw PlatformException(code: 'read', message: 'Java NullPointerException: secret diagnostic');
  });
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await sync.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });
  await tester.pumpWidget(
    MaterialApp(
      home: LibraryScreen(storage: storage, sync: sync, importService: importer),
    ),
  );
  await tester.pumpAndSettle();
  return _Fixture(storage, importer);
}

class _Fixture {
  _Fixture(this.storage, this.importer);
  final _Storage storage;
  final _Importer importer;
}

class _Storage extends StorageService {
  LibraryManifest manifest = LibraryManifest(accountId: 'test-account', deviceId: 'test-device');
  LibraryRoot root = const LibraryRoot(
    kind: LibraryRootKind.desktopPath,
    locator: '/first',
    displayName: 'First folder',
  );
  bool failSecrets = false;
  int chooseCalls = 0;
  int readCalls = 0;
  int scanCalls = 0;

  @override
  Future<LibraryManifest> loadManifest() async {
    readCalls++;
    if (failSecrets) await PlatformLibrarySecretStore().read(LibraryRepository.accountKeySecret);
    return manifest;
  }

  @override
  Future<bool> resumePendingLibraryMigration() async => false;
  @override
  Future<LibraryRoot?> configuredLibraryRoot() async => root;
  @override
  Future<LibraryRootStatus?> libraryRootStatus() async => LibraryRootStatus.available;
  @override
  Future<LibraryScanResult?> refreshLibrary({bool afterPending = false}) async {
    scanCalls++;
    return null;
  }

  @override
  Future<bool> ensurePortableStateOnStartup() async => false;
  @override
  Future<LibraryRoot?> chooseLibraryRootCandidate() async {
    chooseCalls++;
    return const LibraryRoot(kind: LibraryRootKind.desktopPath, locator: '/second', displayName: 'Second folder');
  }

  @override
  Future<PortableLibraryInspection> inspectPortableLibrary(LibraryRoot root) async =>
      const PortableLibraryInspection(disposition: PortableLibraryDisposition.empty);
  @override
  Future<void> configureLibraryRoot(LibraryRoot root, {bool bootstrapPortableState = true}) async => this.root = root;
}

class _Importer extends BookImportService {
  _Importer(this.storage) : super(storage);
  final _Storage storage;
  bool failImport = false;
  int pickCalls = 0;

  @override
  Future<BookRecord?> pickAndImport() async {
    pickCalls++;
    if (failImport) throw PlatformException(code: 'saf_permission', message: 'Java NullPointerException: private path');
    final book = BookRecord(id: 'book', title: 'Imported book', fileName: 'book.txt', format: 'txt', sizeBytes: 13);
    storage.manifest = storage.manifest.copyWith(books: [book]);
    return book;
  }
}
