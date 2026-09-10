import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:readarc/services/library_repository.dart';
import 'package:readarc/services/storage_service.dart';

void main() {
  test('default repository resolves its application directory without recursion', () async {
    final directory = await Directory.systemTemp.createTemp('readarc-storage-service-');
    addTearDown(() async => directory.delete(recursive: true));
    final storage = StorageService(appDirectory: () async => directory, secretStore: _MemorySecretStore());

    final first = await storage.loadManifest().timeout(const Duration(seconds: 3));
    final second = await storage.loadManifest().timeout(const Duration(seconds: 3));

    expect(first.accountId, isNotEmpty);
    expect(second.accountId, first.accountId);
    expect(await File('${directory.path}/manifest.json').exists(), isTrue);
  });

  test('cold-start application directory resolution is single-flight', () async {
    final directory = await Directory.systemTemp.createTemp('readarc-storage-single-flight-');
    addTearDown(() async => directory.delete(recursive: true));
    var resolutions = 0;
    final gate = Completer<void>();
    final storage = StorageService(
      appDirectory: () async {
        resolutions += 1;
        await gate.future;
        return directory;
      },
      secretStore: _MemorySecretStore(),
    );

    final first = storage.appDir();
    final second = storage.appDir();
    final third = storage.appDir();
    await Future<void>.delayed(Duration.zero);

    expect(resolutions, 1, reason: 'parallel cold-start consumers must share one directory/migration lookup');
    gate.complete();
    final resolved = await Future.wait([first, second, third]);
    expect(resolved.map((item) => item.path).toSet(), {directory.path});
    expect(resolutions, 1);

    expect((await storage.appDir()).path, directory.path);
    expect(resolutions, 1, reason: 'resolved app directory must be reused for the lifetime of StorageService');
  });
}

class _MemorySecretStore implements LibrarySecretStore {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;
}
