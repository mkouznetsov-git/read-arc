import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readarc/app/readarc_app.dart';
import 'package:readarc/services/library_repository.dart';
import 'package:readarc/services/storage_service.dart';
import 'package:readarc/services/sync/sync_service.dart';

void main() {
  testWidgets('pairing code survives landscape IME open, close and portrait restore without overflow', (tester) async {
    final directory = await Directory.systemTemp.createTemp('readarc-orientation-ime-');
    final storage = StorageService(appDirectory: () async => directory, secretStore: _MemorySecretStore());
    final sync = SyncService(storage);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 360);

    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      tester.view.resetViewInsets();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      await sync.dispose();
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: SyncScreen(storage: storage, sync: sync),
      ),
    );

    final pairingField = find.byType(TextField);
    for (var attempt = 0; attempt < 20 && pairingField.evaluate().isEmpty; attempt += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(pairingField, findsOneWidget);
    await tester.enterText(pairingField, '123456');
    tester.view.viewInsets = const FakeViewPadding(bottom: 180);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(find.text('Подключиться по коду'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);

    tester.view.resetViewInsets();
    tester.view.physicalSize = const Size(360, 800);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('123456'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _MemorySecretStore implements LibrarySecretStore {
  final _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;
}
