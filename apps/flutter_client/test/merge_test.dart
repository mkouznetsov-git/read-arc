import 'package:flutter_test/flutter_test.dart';
import 'package:readarc/models/book.dart';
import 'package:readarc/models/manifest.dart';
import 'package:readarc/services/sync/merge.dart';

void main() {
  test('merge keeps local path but accepts newer progress', () {
    final localBook = BookRecord(
      id: 'book-1',
      title: 'Book',
      fileName: 'book.txt',
      format: 'txt',
      sizeBytes: 10,
      contentSha256: 'book-1',
      localPath: '/local/book.txt',
      progressPercent: 10,
      progressVersion: 1,
      updatedByDeviceId: 'a',
      availableOnDeviceIds: const ['a'],
    );
    final remoteBook = BookRecord(
      id: 'book-1',
      title: 'Book',
      fileName: 'book.txt',
      format: 'txt',
      sizeBytes: 10,
      contentSha256: 'book-1',
      localPath: '/remote/book.txt',
      progressPercent: 50,
      progressVersion: 2,
      updatedByDeviceId: 'b',
      availableOnDeviceIds: const ['b'],
    );

    final merged = mergeManifests(
      LibraryManifest(accountId: 'acc', deviceId: 'a', books: [localBook]),
      LibraryManifest(accountId: 'acc', deviceId: 'b', books: [remoteBook]),
    );

    expect(merged.books.single.localPath, '/local/book.txt');
    expect(merged.books.single.progressPercent, 50);
    expect(merged.books.single.availableOnDeviceIds, ['a', 'b']);
  });

  test('snapshot sender authoritatively removes only its own stale availability', () {
    final localBook = BookRecord(
      id: 'book-availability',
      title: 'Book',
      fileName: 'book.epub',
      format: 'epub',
      sizeBytes: 10,
      contentSha256: 'book-availability',
      relativeLocation: 'book.epub',
      sourceAvailability: 'available',
      availableOnDeviceIds: const ['a', 'b'],
    );
    final remoteBook = localBook.copyWith(
      clearLocalPath: true,
      clearRelativeLocation: true,
      sourceAvailability: 'unavailable',
      availableOnDeviceIds: const [],
    );

    final merged = mergeManifests(
      LibraryManifest(accountId: 'acc', deviceId: 'b', books: [localBook]),
      LibraryManifest(accountId: 'acc', deviceId: 'a', books: [remoteBook]),
    );

    expect(merged.books.single.availableOnDeviceIds, ['b']);
    expect(merged.books.single.relativeLocation, 'book.epub');
  });

  test('merge remote-only book into local library', () {
    final remoteBook = BookRecord(
      id: 'book-2',
      title: 'Remote Book',
      fileName: 'remote.epub',
      format: 'epub',
      sizeBytes: 10,
      contentSha256: 'book-2',
      localPath: '/remote/remote.epub',
      availableOnDeviceIds: const ['b'],
    );

    final merged = mergeManifests(
      LibraryManifest(accountId: 'acc', deviceId: 'a'),
      LibraryManifest(accountId: 'acc', deviceId: 'b', books: [remoteBook]),
    );

    expect(merged.books.single.title, 'Remote Book');
    expect(merged.books.single.localPath, isNull);
    expect(merged.books.single.availableOnDeviceIds, ['b']);
  });

  test('merge bookmarks keeps both devices changes', () {
    final localBookmark = BookmarkRecord(
      id: 'bookmark-a',
      bookId: 'book-1',
      label: 'Mac bookmark',
      locator: 'txt-scroll:10',
    );
    final remoteBookmark = BookmarkRecord(
      id: 'bookmark-b',
      bookId: 'book-1',
      label: 'Android bookmark',
      locator: 'txt-scroll:20',
    );
    final localBook = BookRecord(
      id: 'book-1',
      title: 'Book',
      fileName: 'book.txt',
      format: 'txt',
      sizeBytes: 10,
      contentSha256: 'book-1',
      localPath: '/local/book.txt',
      bookmarks: [localBookmark],
      availableOnDeviceIds: const ['a'],
    );
    final remoteBook = BookRecord(
      id: 'book-1',
      title: 'Book',
      fileName: 'book.txt',
      format: 'txt',
      sizeBytes: 10,
      contentSha256: 'book-1',
      localPath: '/remote/book.txt',
      bookmarks: [remoteBookmark],
      availableOnDeviceIds: const ['b'],
    );

    final merged = mergeManifests(
      LibraryManifest(accountId: 'acc', deviceId: 'a', books: [localBook]),
      LibraryManifest(accountId: 'acc', deviceId: 'b', books: [remoteBook]),
    );

    expect(merged.books.single.bookmarks.map((b) => b.id), ['bookmark-a', 'bookmark-b']);
  });

  test('merge trusted devices from both manifests', () {
    final merged = mergeManifests(
      LibraryManifest(
        accountId: 'acc',
        deviceId: 'a',
        trustedDevices: [TrustedDeviceRecord(deviceId: 'a', name: 'Mac', role: 'owner')],
      ),
      LibraryManifest(
        accountId: 'acc',
        deviceId: 'b',
        trustedDevices: [TrustedDeviceRecord(deviceId: 'b', name: 'Android')],
      ),
    );

    expect(merged.trustedDevices.map((d) => d.deviceId).toSet(), {'a', 'b'});
  });

  test('merge keeps deterministic alphabetical library order', () {
    final zebra = BookRecord(
      id: 'z',
      title: 'Zebra',
      fileName: 'zebra.txt',
      format: 'txt',
      sizeBytes: 10,
      contentSha256: 'z',
      updatedAt: DateTime.utc(2030),
    );
    final alpha = BookRecord(
      id: 'a',
      title: 'Alpha',
      fileName: 'alpha.txt',
      format: 'txt',
      sizeBytes: 10,
      contentSha256: 'a',
      updatedAt: DateTime.utc(2020),
    );

    final merged = mergeManifests(
      LibraryManifest(accountId: 'acc', deviceId: 'a', books: [zebra]),
      LibraryManifest(accountId: 'acc', deviceId: 'b', books: [alpha]),
    );

    expect(merged.visibleBooks.map((b) => b.title), ['Alpha', 'Zebra']);
  });

  test('deleted book tombstone hides book from visible library', () {
    final localBook = BookRecord(
      id: 'book-1',
      title: 'Book',
      fileName: 'book.txt',
      format: 'txt',
      sizeBytes: 10,
      contentSha256: 'book-1',
      localPath: '/local/book.txt',
      availableOnDeviceIds: const ['a'],
    );
    final remoteBook = localBook.copyWith(
      clearLocalPath: true,
      availableOnDeviceIds: const [],
      deletedAt: DateTime.utc(2030),
      updatedAt: DateTime.utc(2030),
    );

    final merged = mergeManifests(
      LibraryManifest(accountId: 'acc', deviceId: 'a', books: [localBook]),
      LibraryManifest(accountId: 'acc', deviceId: 'b', books: [remoteBook]),
    );

    expect(merged.books.single.isDeleted, isTrue);
    expect(merged.visibleBooks, isEmpty);
  });

  test('newer active local book wins over older remote deletion tombstone', () {
    final localBook = BookRecord(
      id: 'book-1',
      title: 'Reimported Book',
      fileName: 'book.fb2',
      format: 'fb2',
      sizeBytes: 10,
      contentSha256: 'book-1',
      localPath: '/local/book.fb2',
      updatedAt: DateTime.utc(2030),
      availableOnDeviceIds: const ['mac'],
    );
    final remoteTombstone = localBook.copyWith(
      clearLocalPath: true,
      availableOnDeviceIds: const [],
      deletedAt: DateTime.utc(2029),
      updatedAt: DateTime.utc(2029),
    );

    final merged = mergeManifests(
      LibraryManifest(accountId: 'acc', deviceId: 'mac', books: [localBook]),
      LibraryManifest(accountId: 'acc', deviceId: 'android', books: [remoteTombstone]),
    );

    expect(merged.books.single.isDeleted, isFalse);
    expect(merged.visibleBooks.single.title, 'Reimported Book');
    expect(merged.books.single.localPath, '/local/book.fb2');
  });

  test('newer remote deletion tombstone still hides older active book', () {
    final localBook = BookRecord(
      id: 'book-1',
      title: 'Book',
      fileName: 'book.fb2',
      format: 'fb2',
      sizeBytes: 10,
      contentSha256: 'book-1',
      localPath: '/local/book.fb2',
      updatedAt: DateTime.utc(2029),
      availableOnDeviceIds: const ['mac'],
    );
    final remoteTombstone = localBook.copyWith(
      clearLocalPath: true,
      availableOnDeviceIds: const [],
      deletedAt: DateTime.utc(2030),
      updatedAt: DateTime.utc(2030),
    );

    final merged = mergeManifests(
      LibraryManifest(accountId: 'acc', deviceId: 'mac', books: [localBook]),
      LibraryManifest(accountId: 'acc', deviceId: 'android', books: [remoteTombstone]),
    );

    expect(merged.books.single.isDeleted, isTrue);
    expect(merged.visibleBooks, isEmpty);
  });

  test('deleted trusted device is hidden from active devices', () {
    final removed = TrustedDeviceRecord(deviceId: 'old-device', name: 'Old phone', deletedAt: DateTime.utc(2030));
    final current = TrustedDeviceRecord(deviceId: 'a', name: 'Mac', role: 'owner');

    final manifest = LibraryManifest(accountId: 'acc', deviceId: 'a', trustedDevices: [removed, current]);

    expect(manifest.activeTrustedDevices.map((d) => d.deviceId), ['a']);
  });
}
