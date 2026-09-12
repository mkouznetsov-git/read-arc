import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:crypto/crypto.dart';
import 'package:readarc/main.dart' as app;
import 'package:readarc/models/book.dart';
import 'package:readarc/models/manifest.dart';
import 'package:readarc/services/storage_service.dart';
import 'package:readarc/services/library_storage.dart';
import 'package:readarc/services/sync/sync_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ReadArc migrates a pre-Sprint-46 manifest and opens the library', (tester) async {
    final errors = <FlutterErrorDetails>[];
    final previousHandler = FlutterError.onError;
    FlutterError.onError = errors.add;
    addTearDown(() => FlutterError.onError = previousHandler);

    final directory = await Directory.systemTemp.createTemp('readarc-platform-upgrade-smoke-');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    final booksDirectory = Directory('${directory.path}/books');
    await booksDirectory.create(recursive: true);
    final legacyBookFile = File('${booksDirectory.path}/legacy.txt');
    await legacyBookFile.writeAsString('preserved book payload', flush: true);
    final legacySha = (await sha256.bind(legacyBookFile.openRead()).first).toString();
    final legacyBookmark = BookmarkRecord(
      id: 'legacy-bookmark',
      bookId: legacySha,
      label: 'Preserved bookmark',
      locator: 'paragraph:42',
      note: 'Migration must retain this note',
    );
    final legacyBook = BookRecord(
      id: legacySha,
      title: 'Preserved legacy book',
      fileName: 'legacy.txt',
      format: 'txt',
      sizeBytes: await legacyBookFile.length(),
      contentSha256: legacySha,
      localPath: legacyBookFile.path,
      progressPercent: 64,
      currentLocator: 'paragraph:42',
      progressVersion: 7,
      updatedByDeviceId: 'legacy-device',
      availableOnDeviceIds: const ['legacy-device'],
      bookmarks: [legacyBookmark],
    );
    final legacy =
        LibraryManifest(
            accountId: 'legacy-account',
            accountEncryptionKey: 'legacy-account-secret',
            deviceId: 'legacy-device',
            deviceName: 'Legacy device',
            deviceSigningPublicKey: 'legacy-public',
            deviceSigningPrivateKey: 'legacy-device-secret',
            trustedDevices: [
              TrustedDeviceRecord(deviceId: 'legacy-device', name: 'Legacy device', role: 'owner'),
              TrustedDeviceRecord(deviceId: 'paired-device', name: 'Paired phone'),
            ],
            books: [legacyBook],
          ).toJson()
          ..remove('schemaVersion')
          ..['accountEncryptionKey'] = 'legacy-account-secret'
          ..['deviceSigningPrivateKey'] = 'legacy-device-secret';
    final legacyBookJson = (legacy['books'] as List).single as Map<String, dynamic>;
    legacyBookJson
      ..remove('metadataRevision')
      ..remove('progressRevision')
      ..remove('tombstoneAckedByDeviceIds');
    final legacyBookmarkJson = (legacyBookJson['bookmarks'] as List).single as Map<String, dynamic>;
    legacyBookmarkJson
      ..remove('revision')
      ..remove('tombstoneAckedByDeviceIds');
    final manifestFile = File('${directory.path}/manifest.json');
    await manifestFile.writeAsString(jsonEncode(legacy), flush: true);

    final userLibrary = Directory('${directory.path}/user-library');
    await userLibrary.create();
    final storage = _SmokeStorage(directory);
    await storage.configureLibraryRoot(
      LibraryRoot(kind: LibraryRootKind.desktopPath, locator: userLibrary.path, displayName: 'Library'),
    );
    final sync = SyncService(storage);
    await tester.pumpWidget(app.ReadArcApp(autoConnect: false, storage: storage, sync: sync, disposeSync: false));
    try {
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 20),
      );

      expect(find.byType(MaterialApp), findsOneWidget);
      expect(find.byType(app.LibraryScreen), findsOneWidget);
      expect(find.text('Preserved legacy book'), findsOneWidget);
      expect(find.textContaining('Не удалось загрузить библиотеку'), findsNothing);
      expect(errors, isEmpty, reason: 'ReadArc emitted a Flutter framework error during upgrade startup: $errors');

      final migrated = await storage.loadManifest();
      expect(migrated.accountId, 'legacy-account');
      expect(migrated.deviceId, 'legacy-device');
      expect(migrated.deviceName, 'Legacy device');
      expect(migrated.deviceSigningPublicKey, 'legacy-public');
      expect(migrated.accountEncryptionKey, 'legacy-account-secret');
      expect(migrated.deviceSigningPrivateKey, 'legacy-device-secret');
      expect(migrated.trustedDevices.map((device) => device.deviceId), containsAll(['legacy-device', 'paired-device']));
      expect(migrated.books, hasLength(1));
      final migratedBook = migrated.books.single;
      expect(migratedBook.id, legacySha);
      expect(migratedBook.localPath, isNull);
      expect(migratedBook.relativeLocation, 'legacy.txt');
      expect(migratedBook.progressPercent, 64);
      expect(migratedBook.currentLocator, 'paragraph:42');
      expect(migratedBook.progressRevision.counter, 7);
      expect(migratedBook.bookmarks.single.id, 'legacy-bookmark');
      expect(migratedBook.bookmarks.single.note, 'Migration must retain this note');
      expect(await legacyBookFile.readAsString(), 'preserved book payload');

      final migratedRaw = await manifestFile.readAsString();
      final migratedJson = jsonDecode(migratedRaw) as Map<String, dynamic>;
      expect(migratedJson['schemaVersion'], LibraryManifest.currentSchemaVersion);
      expect(migratedRaw, isNot(contains('legacy-account-secret')));
      expect(migratedRaw, isNot(contains('legacy-device-secret')));
      final backupDirectory = Directory('${directory.path}/manifest_backups');
      expect(await backupDirectory.exists(), isTrue);
      expect(await backupDirectory.list().where((entry) => entry is File).isEmpty, isFalse);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
      await sync.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('ReadArc creates its initial manifest and opens the empty library', (tester) async {
    final errors = <FlutterErrorDetails>[];
    final previousHandler = FlutterError.onError;
    FlutterError.onError = errors.add;
    addTearDown(() => FlutterError.onError = previousHandler);

    final directory = await Directory.systemTemp.createTemp('readarc-platform-smoke-');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final storage = _SmokeStorage(directory);
    final userLibrary = Directory('${directory.path}/user-library');
    await userLibrary.create();
    await storage.configureLibraryRoot(
      LibraryRoot(kind: LibraryRootKind.desktopPath, locator: userLibrary.path, displayName: 'Library'),
    );
    final sync = SyncService(storage);
    // Relay behavior has its own real two-client integration harness. Keep the
    // platform boot smoke deterministic and independent from production DNS,
    // internet reachability and live peer traffic.
    await tester.pumpWidget(app.ReadArcApp(autoConnect: false, storage: storage, sync: sync, disposeSync: false));
    try {
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 20),
      );

      expect(find.byType(MaterialApp), findsOneWidget);
      expect(find.byType(app.LibraryScreen), findsOneWidget);
      expect(find.textContaining('В выбранной папке пока нет'), findsOneWidget);
      expect(find.textContaining('Не удалось загрузить библиотеку'), findsNothing);
      expect(errors, isEmpty, reason: 'ReadArc emitted a Flutter framework error during startup: $errors');
    } finally {
      // Explicitly dispose application-owned sync streams, timers and HTTP
      // resources. Device integration runners keep the process alive while any
      // of these resources remain attached to the widget under test.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
      await sync.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}

class _SmokeStorage extends StorageService {
  _SmokeStorage(Directory directory)
    : super(appDirectory: () async => directory, libraryStorageProvider: LocalDirectoryLibraryStorageProvider());
}
