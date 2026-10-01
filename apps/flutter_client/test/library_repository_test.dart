import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:readarc/models/book.dart';
import 'package:readarc/models/manifest.dart';
import 'package:readarc/services/library_repository.dart';
import 'package:readarc/services/sync/merge.dart';

void main() {
  late Directory directory;
  late MemorySecretStore secrets;
  late LibraryRepository repository;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('readarc_repository_');
    secrets = MemorySecretStore();
    repository = _repository(directory, secrets);
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('two concurrent mutations retain both changes', () async {
    await repository.read();
    await Future.wait([
      repository.mutate((current) => current.copyWith(books: [...current.books, _book('a')])),
      repository.mutate((current) => current.copyWith(books: [...current.books, _book('b')])),
      repository.mutate((current) => current.copyWith(books: [...current.books, _book('c')])),
    ]);

    expect((await repository.read()).books.map((book) => book.id).toSet(), {'a', 'b', 'c'});
  });

  test('progress save concurrent with import retains both', () async {
    await repository.mutate((current) => current.copyWith(books: [_book('a')]));
    await Future.wait([
      repository.mutate(
        (current) => current.copyWith(
          books: current.books
              .map((book) => book.id == 'a' ? book.copyWith(progressPercent: 42, currentLocator: 'p42') : book)
              .toList(),
        ),
      ),
      repository.mutate((current) => current.copyWith(books: [...current.books, _book('imported')])),
    ]);

    final saved = await repository.read();
    expect(saved.books.singleWhere((book) => book.id == 'a').progressPercent, 42);
    expect(saved.books.any((book) => book.id == 'imported'), isTrue);
  });

  test('sync snapshot concurrent with local mutation is merged against current state', () async {
    await repository.mutate((current) => current.copyWith(books: [_book('local')]));
    final remote = LibraryManifest(accountId: 'account', deviceId: 'remote', books: [_book('remote')]);
    await Future.wait([
      repository.mutate((current) => current.copyWith(books: [...current.books, _book('during-sync')])),
      repository.mutate((current) => mergeManifests(current, remote)),
    ]);

    expect((await repository.read()).books.map((book) => book.id).toSet(), {'local', 'during-sync', 'remote'});
  });

  test('orphan temp file from interrupted write does not replace manifest', () async {
    await repository.mutate((current) => current.copyWith(books: [_book('safe')]));
    await File(p.join(directory.path, 'manifest.json.tmp-interrupted')).writeAsString('{"books":');

    expect((await _repository(directory, secrets).read()).books.single.id, 'safe');
  });

  test('corrupt primary manifest recovers from latest valid backup', () async {
    await repository.mutate((current) => current.copyWith(books: [_book('generation-1')]));
    await repository.mutate((current) => current.copyWith(books: [...current.books, _book('generation-2')]));
    await File(p.join(directory.path, 'manifest.json')).writeAsString('{broken');

    final recovered = await _repository(directory, secrets).read();
    expect(recovered.books.map((book) => book.id), contains('generation-1'));
    expect(Directory(p.join(directory.path, 'manifest_recovery')).existsSync(), isTrue);
  });

  test('corrupt primary and newest backup falls back to older verified generation', () async {
    await repository.mutate((current) => current.copyWith(books: [_book('oldest')]));
    await repository.mutate((current) => current.copyWith(books: [...current.books, _book('middle')]));
    await repository.mutate((current) => current.copyWith(books: [...current.books, _book('newest')]));
    final backupDirectory = Directory(p.join(directory.path, 'manifest_backups'));
    final backups = backupDirectory.listSync().whereType<File>().toList()..sort((a, b) => b.path.compareTo(a.path));
    await backups.first.writeAsString('');
    await File(p.join(directory.path, 'manifest.json')).writeAsString('[]');

    final recovered = await _repository(directory, secrets).read();
    expect(recovered.books.any((book) => book.id == 'oldest'), isTrue);
  });

  test('corrupt primary with no valid backup fails diagnostically instead of creating an empty library', () async {
    await repository.read();
    await File(p.join(directory.path, 'manifest.json')).writeAsString('');

    await expectLater(_repository(directory, secrets).read(), throwsA(isA<ManifestRecoveryException>()));
    expect(File(p.join(directory.path, 'manifest.json')).readAsStringSync(), isEmpty);
  });

  test('secure-storage failure preserves a valid manifest instead of quarantining or resetting it', () async {
    await repository.mutate((current) => current.copyWith(books: [_book('preserved')]));
    final manifestFile = File(p.join(directory.path, 'manifest.json'));
    final original = await manifestFile.readAsString();
    final failing = _repository(directory, _UnavailableSecretStore());

    await expectLater(failing.read(), throwsA(isA<SecureStorageUnavailableException>()));

    expect(await manifestFile.readAsString(), original);
    expect(Directory(p.join(directory.path, 'manifest_recovery')).existsSync(), isFalse);
    expect(Directory(p.join(directory.path, 'manifest_rejected')).existsSync(), isFalse);
  });

  test('legacy manifest migrates once, strips secrets and remains idempotent', () async {
    final legacy = _initial().toJson()
      ..remove('schemaVersion')
      ..['accountEncryptionKey'] = 'legacy-account-key'
      ..['deviceSigningPrivateKey'] = 'legacy-device-key';
    final manifestFile = File(p.join(directory.path, 'manifest.json'));
    await manifestFile.writeAsString(jsonEncode(legacy));

    final first = await repository.read();
    final firstDisk = await manifestFile.readAsString();
    final second = await _repository(directory, secrets).read();

    expect(first.schemaVersion, LibraryManifest.currentSchemaVersion);
    expect(second.schemaVersion, LibraryManifest.currentSchemaVersion);
    expect(secrets.values[LibraryRepository.accountKeySecret], 'legacy-account-key');
    expect(secrets.values[LibraryRepository.devicePrivateKeySecret], 'legacy-device-key');
    expect(firstDisk, isNot(contains('legacy-account-key')));
    expect(firstDisk, isNot(contains('legacy-device-key')));
  });

  test('failed legacy secret migration preserves the original manifest and a recovery copy', () async {
    final legacy = _initial().copyWith(books: [_book('preserved')]).toJson()
      ..remove('schemaVersion')
      ..['accountEncryptionKey'] = 'legacy-account-key'
      ..['deviceSigningPrivateKey'] = 'legacy-device-key';
    final raw = jsonEncode(legacy);
    final manifestFile = File(p.join(directory.path, 'manifest.json'));
    await manifestFile.writeAsString(raw, flush: true);
    secrets.failWrites = true;

    await expectLater(repository.read(), throwsA(isA<ManifestRecoveryException>()));
    expect(await manifestFile.readAsString(), raw);
    final recoveryDirectory = Directory(p.join(directory.path, 'manifest_recovery'));
    final recoveryCopies = await recoveryDirectory
        .list()
        .where((entry) => entry is File && p.basename(entry.path).startsWith('broken_manifest_'))
        .toList();
    expect(recoveryCopies, isNotEmpty);

    secrets.failWrites = false;
    final retried = await _repository(directory, secrets).read();
    expect(retried.books.single.id, 'preserved');
    expect(retried.accountEncryptionKey, 'legacy-account-key');
    expect(retried.deviceSigningPrivateKey, 'legacy-device-key');
  });

  test('schema v2 is durably migrated to logical revisions in schema v3', () async {
    final book = _book('legacy-book').toJson()
      ..remove('metadataRevision')
      ..remove('progressRevision')
      ..remove('tombstoneAckedByDeviceIds')
      ..['progressVersion'] = 7
      ..['updatedByDeviceId'] = 'legacy-device';
    final v2 = _initial().toJson()
      ..['schemaVersion'] = 2
      ..remove('logicalClock')
      ..remove('appliedOperationIds')
      ..['books'] = [book];
    final manifestFile = File(p.join(directory.path, 'manifest.json'));
    await manifestFile.writeAsString(jsonEncode(v2));

    final migrated = await repository.read();
    final persisted = jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;

    expect(migrated.schemaVersion, 3);
    expect(migrated.logicalClock, 7);
    expect(migrated.books.single.progressRevision.counter, 7);
    expect(persisted['schemaVersion'], 3);
    expect((persisted['books'] as List).single, contains('progressRevision'));
  });

  test('restart retains books, progress, bookmarks and pairing metadata', () async {
    final bookmark = BookmarkRecord(id: 'bookmark', bookId: 'book', label: 'Saved', locator: 'loc');
    await repository.mutate(
      (current) => current.copyWith(
        books: [
          _book('book').copyWith(progressPercent: 64, currentLocator: 'loc', bookmarks: [bookmark]),
        ],
        trustedDevices: [
          ...current.trustedDevices,
          TrustedDeviceRecord(deviceId: 'paired', name: 'Phone'),
        ],
      ),
    );

    final restarted = await _repository(directory, secrets).read();
    expect(restarted.books.single.progressPercent, 64);
    expect(restarted.books.single.bookmarks.single.id, 'bookmark');
    expect(restarted.trustedDevices.any((device) => device.deviceId == 'paired'), isTrue);
  });

  test('write failure leaves the previous library readable and non-empty', () async {
    await repository.mutate((current) => current.copyWith(books: [_book('preserved')]));
    secrets.failWrites = true;
    await expectLater(
      repository.mutate((current) => current.copyWith(books: [...current.books, _book('not-committed')])),
      throwsA(isA<FileSystemException>()),
    );
    secrets.failWrites = false;

    expect((await _repository(directory, secrets).read()).books.single.id, 'preserved');
  });
}

LibraryRepository _repository(Directory directory, LibrarySecretStore secrets) => LibraryRepository(
  appDirectory: () async => directory,
  secretStore: secrets,
  createInitialManifest: () async => _initial(),
  normalize: (manifest) => manifest,
);

LibraryManifest _initial() => LibraryManifest(
  accountId: 'account',
  accountEncryptionKey: 'account-secret',
  deviceId: 'device',
  deviceName: 'Test device',
  deviceSigningPublicKey: 'public',
  deviceSigningPrivateKey: 'private-secret',
  trustedDevices: [TrustedDeviceRecord(deviceId: 'device', name: 'Test device', role: 'owner')],
);

BookRecord _book(String id) => BookRecord(
  id: id,
  title: id,
  fileName: '$id.txt',
  format: 'txt',
  sizeBytes: 1,
  contentSha256: id,
  localPath: '/tmp/$id.txt',
  availableOnDeviceIds: const ['device'],
);

class MemorySecretStore implements LibrarySecretStore {
  final values = <String, String>{};
  bool failWrites = false;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw const FileSystemException('No space left on device');
    values[key] = value;
  }
}

class _UnavailableSecretStore implements LibrarySecretStore {
  @override
  Future<String?> read(String key) async => throw const SecureStorageUnavailableException();

  @override
  Future<void> write(String key, String value) async => throw const SecureStorageUnavailableException();
}
