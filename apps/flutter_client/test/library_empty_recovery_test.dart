import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readarc/app/readarc_app.dart';
import 'package:readarc/services/book_import_service.dart';
import 'package:readarc/services/library_repository.dart';
import 'package:readarc/services/library_storage.dart';
import 'package:readarc/services/storage_service.dart';
import 'package:readarc/services/sync/sync_service.dart';

void main() {
  testWidgets('empty library can change root and import a streamed book without restart', (tester) async {
    final fixture = await _mount(tester);
    expect(find.text('Папка: First folder'), findsOneWidget);
    await tester.tap(find.text('Сменить папку'));
    await _waitFor(tester, find.text('Папка: second'));
    expect(fixture.provider.chooseCalls, 1);

    await tester.tap(find.widgetWithText(FilledButton, 'Добавить книгу'));
    await _waitFor(tester, find.text('streamed'));
    expect(fixture.pickCalls, 1);
    expect(find.text('В выбранной библиотеке пока нет книг'), findsNothing);
    await tester.runAsync(() async {
      expect((await fixture.storage.loadManifest()).visibleBooks, hasLength(1));
      expect(await File('${fixture.directory.path}/second/streamed.txt').readAsString(), 'streamed book');
      expect(await Directory('${fixture.directory.path}/app/import_staging').list().toList(), isEmpty);
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets('SAF import failure is visible and retry succeeds without raw plugin details', (tester) async {
    final fixture = await _mount(tester);
    fixture.provider.failImport = true;
    await tester.tap(find.widgetWithText(FilledButton, 'Добавить книгу'));
    await _waitFor(tester, find.textContaining('Не удалось прочитать выбранный файл'));
    expect(find.textContaining('PlatformException'), findsNothing);
    expect(find.textContaining('NullPointerException'), findsNothing);
    expect(find.text('Папка: First folder'), findsOneWidget);
    fixture.provider.failImport = false;
    await tester.tap(find.widgetWithText(FilledButton, 'Добавить книгу'));
    await _waitFor(tester, find.text('streamed'));
    expect(fixture.pickCalls, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unreadable platform secrets show recovery guidance and preserve manifest on retry', (tester) async {
    final fixture = await _mount(tester, failSecrets: true);
    final guidance = find.textContaining('Защищённые данные этой установки недоступны');
    expect(guidance, findsOneWidget);
    expect(find.textContaining('Recovery Key'), findsOneWidget);
    expect(find.textContaining('PlatformException'), findsNothing);
    expect(find.textContaining('NullPointerException'), findsNothing);
    expect(tester.widget<FloatingActionButton>(find.byType(FloatingActionButton)).onPressed, isNull);
    await tester.tap(find.text('Повторить'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(guidance, findsOneWidget);
    await tester.runAsync(() async {
      expect(await File('${fixture.directory.path}/app/manifest.json').readAsString(), fixture.originalManifest);
      expect(await Directory('${fixture.directory.path}/app/manifest_recovery').exists(), isFalse);
    });
    expect(tester.takeException(), isNull);
  });
}

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 200 && finder.evaluate().isEmpty; attempt++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
    await tester.pump();
  }
  expect(finder, findsOneWidget);
}

Future<_Fixture> _mount(WidgetTester tester, {bool failSecrets = false}) async {
  final directory = (await tester.runAsync(() => Directory.systemTemp.createTemp('readarc-empty-ui-')))!;
  final provider = _Provider(
    LibraryRoot(kind: LibraryRootKind.desktopPath, locator: '${directory.path}/second', displayName: 'Second folder'),
  );
  final secrets = _Secrets();
  // Storage owns an initially pending Future.value() write queue. Construct
  // and initialize it in the real async zone so runAsync never waits for a
  // microtask trapped in the widget test's fake clock.
  final storage = (await tester.runAsync(() async {
    final storage = StorageService(
      appDirectory: () async => Directory('${directory.path}/app'),
      secretStore: secrets,
      libraryStorageProvider: provider.storage,
    );
    await Directory('${directory.path}/first').create();
    await Directory('${directory.path}/second').create();
    await storage.configureLibraryRoot(
      LibraryRoot(kind: LibraryRootKind.desktopPath, locator: '${directory.path}/first', displayName: 'First folder'),
    );
    return storage;
  }))!;
  final fixture = _Fixture(directory, provider, storage);
  fixture.originalManifest = (await tester.runAsync(() => File('${directory.path}/app/manifest.json').readAsString()))!;
  // Exercise the real PlatformLibrarySecretStore exception translation, too.
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  if (failSecrets) {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'read', message: 'Java NullPointerException: secret diagnostic');
    });
    secrets.platform = PlatformLibrarySecretStore();
  }
  final sync = SyncService(storage);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    messenger.setMockMethodCallHandler(channel, null);
    await tester.runAsync(() async {
      await sync.dispose();
      secrets.platform = null;
      await storage.dispose();
      await directory.delete(recursive: true);
    });
  });
  await tester.pumpWidget(
    MaterialApp(
      home: LibraryScreen(
        storage: storage,
        sync: sync,
        importService: BookImportService(
          storage,
          pickBookFile: () async {
            fixture.pickCalls++;
            return PlatformFile(name: 'streamed.txt', size: 13, readStream: Stream.value('streamed book'.codeUnits));
          },
        ),
      ),
    ),
  );
  await _waitFor(
    tester,
    find.textContaining(failSecrets ? 'Защищённые данные этой установки недоступны' : 'Папка: First folder'),
  );
  return fixture;
}

class _Fixture {
  _Fixture(this.directory, this.provider, this.storage);
  final Directory directory;
  final _Provider provider;
  final StorageService storage;
  int pickCalls = 0;
  String originalManifest = '';
}

class _Provider {
  _Provider(this.nextRoot);
  final LibraryRoot nextRoot;
  int chooseCalls = 0;
  bool failImport = false;
  late final storage = LocalDirectoryLibraryStorageProvider(
    chooseDirectory: () async {
      chooseCalls++;
      return nextRoot.locator;
    },
    afterStagedCopy: (_) async {
      if (failImport) {
        throw PlatformException(code: 'saf_permission', message: 'Java NullPointerException: private path');
      }
    },
  );
}

class _Secrets implements LibrarySecretStore {
  final values = <String, String>{};
  PlatformLibrarySecretStore? platform;
  @override
  Future<String?> read(String key) async => platform != null ? platform!.read(key) : values[key];
  @override
  Future<void> write(String key, String value) async {
    if (platform != null) return platform!.write(key, value);
    values[key] = value;
  }
}
