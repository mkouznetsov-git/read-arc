import '../../models/book.dart';
import '../../models/manifest.dart';

/// Deterministic, clock-independent metadata merge.
///
/// Wall-clock timestamps remain in the manifest for diagnostics and v2
/// compatibility only. All v3 mutations are ordered by domain-specific Lamport
/// revisions, so a metadata rename cannot overwrite newer reading progress and
/// an old active snapshot cannot defeat a deletion tombstone.
LibraryManifest mergeManifests(LibraryManifest local, LibraryManifest remote) {
  final mergedById = <String, BookRecord>{for (final book in local.books) book.id: book};

  for (final remoteBook in remote.books) {
    final localBook = mergedById[remoteBook.id];
    mergedById[remoteBook.id] = localBook == null
        ? _remoteOnlyBook(remoteBook, local.deviceId)
        : _mergeBook(localBook, remoteBook, local.deviceId);
  }

  final applied = <String>{...local.appliedOperationIds, ...remote.appliedOperationIds}.toList();
  if (applied.length > 4096) applied.removeRange(0, applied.length - 4096);

  return local.copyWith(
    updatedAt: _latest(local.updatedAt, remote.updatedAt),
    logicalClock: local.logicalClock > remote.logicalClock ? local.logicalClock : remote.logicalClock,
    appliedOperationIds: applied,
    trustedDevices: _mergeTrustedDevices(local.trustedDevices, remote.trustedDevices),
    books: mergedById.values.toList()
      ..sort((a, b) {
        if (a.isDeleted != b.isDeleted) return a.isDeleted ? 1 : -1;
        return compareBooksForLibrary(a, b);
      }),
  );
}

BookRecord _remoteOnlyBook(BookRecord remote, String localDeviceId) {
  return BookRecord(
    id: remote.id,
    title: remote.title,
    fileName: remote.fileName,
    format: remote.format,
    sizeBytes: remote.sizeBytes,
    contentSha256: remote.contentSha256,
    localPath: null,
    relativeLocation: null,
    sourceAvailability: 'unavailable',
    addedAt: remote.addedAt,
    updatedAt: remote.updatedAt,
    progressPercent: remote.progressPercent,
    currentLocator: remote.currentLocator,
    progressVersion: remote.progressVersion,
    updatedByDeviceId: remote.updatedByDeviceId,
    deletedAt: remote.deletedAt,
    availableOnDeviceIds: remote.availableOnDeviceIds,
    bookmarks: remote.bookmarks.map((bookmark) => _ackBookmarkTombstone(bookmark, localDeviceId)).toList(),
    metadataRevision: remote.metadataRevision,
    progressRevision: remote.progressRevision,
    tombstoneAckedByDeviceIds: _acknowledgeIfDeleted(
      deleted: remote.isDeleted,
      acknowledgements: remote.tombstoneAckedByDeviceIds,
      deviceId: localDeviceId,
    ),
  );
}

BookRecord _mergeBook(BookRecord local, BookRecord remote, String localDeviceId) {
  final metadataWinner = _metadataCompare(local, remote) >= 0 ? local : remote;
  final progressWinner = _progressCompare(local, remote) >= 0 ? local : remote;
  final bookmarks = _mergeBookmarks(local.bookmarks, remote.bookmarks, localDeviceId);
  final availableOn = <String>{...local.availableOnDeviceIds, ...remote.availableOnDeviceIds}.toList()..sort();
  final deleted = metadataWinner.isDeleted;
  final deletionAcks = deleted
      ? _acknowledgeIfDeleted(
          deleted: true,
          acknowledgements: {...local.tombstoneAckedByDeviceIds, ...remote.tombstoneAckedByDeviceIds}.toList(),
          deviceId: localDeviceId,
        )
      : const <String>[];

  // Local source information is device-local and is never accepted from a
  // remote snapshot. Content SHA remains the cross-device identity.
  return BookRecord(
    id: local.id,
    title: metadataWinner.title,
    fileName: metadataWinner.fileName,
    format: metadataWinner.format,
    sizeBytes: metadataWinner.sizeBytes,
    contentSha256: metadataWinner.contentSha256,
    localPath: deleted ? null : local.localPath,
    relativeLocation: deleted ? null : local.relativeLocation,
    sourceAvailability: deleted ? 'unavailable' : local.sourceAvailability,
    addedAt: local.addedAt.isBefore(remote.addedAt) ? local.addedAt : remote.addedAt,
    updatedAt: _latest(local.updatedAt, remote.updatedAt),
    progressPercent: progressWinner.progressPercent,
    currentLocator: progressWinner.currentLocator,
    progressVersion: progressWinner.progressVersion,
    updatedByDeviceId: progressWinner.updatedByDeviceId,
    deletedAt: deleted ? metadataWinner.deletedAt : null,
    availableOnDeviceIds: deleted ? const [] : availableOn,
    bookmarks: bookmarks,
    metadataRevision: metadataWinner.metadataRevision,
    progressRevision: progressWinner.progressRevision,
    tombstoneAckedByDeviceIds: deletionAcks,
  );
}

int _metadataCompare(BookRecord a, BookRecord b) {
  if (!a.metadataRevision.isZero || !b.metadataRevision.isZero) {
    return a.metadataRevision.compareTo(b.metadataRevision);
  }
  // Compatibility only for schema-v2 manifests. Migration makes all future
  // mutations use Lamport revisions, so device time is not a v3 ordering input.
  final time = a.updatedAt.compareTo(b.updatedAt);
  if (time != 0) return time;
  return a.updatedByDeviceId.compareTo(b.updatedByDeviceId);
}

int _progressCompare(BookRecord a, BookRecord b) {
  if (!a.progressRevision.isZero || !b.progressRevision.isZero) {
    return a.progressRevision.compareTo(b.progressRevision);
  }
  final version = a.progressVersion.compareTo(b.progressVersion);
  if (version != 0) return version;
  final time = a.updatedAt.compareTo(b.updatedAt);
  if (time != 0) return time;
  return a.updatedByDeviceId.compareTo(b.updatedByDeviceId);
}

List<BookmarkRecord> _mergeBookmarks(List<BookmarkRecord> local, List<BookmarkRecord> remote, String localDeviceId) {
  final byId = <String, BookmarkRecord>{};
  for (final item in [...local, ...remote]) {
    final existing = byId[item.id];
    if (existing == null || _bookmarkCompare(item, existing) > 0) byId[item.id] = item;
  }
  return byId.values.map((bookmark) => _ackBookmarkTombstone(bookmark, localDeviceId)).toList()
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
}

int _bookmarkCompare(BookmarkRecord a, BookmarkRecord b) {
  if (!a.revision.isZero || !b.revision.isZero) return a.revision.compareTo(b.revision);
  final time = a.updatedAt.compareTo(b.updatedAt);
  if (time != 0) return time;
  return a.id.compareTo(b.id);
}

BookmarkRecord _ackBookmarkTombstone(BookmarkRecord bookmark, String localDeviceId) {
  if (!bookmark.isDeleted) return bookmark;
  return bookmark.copyWith(
    updatedAt: bookmark.updatedAt,
    tombstoneAckedByDeviceIds: _acknowledgeIfDeleted(
      deleted: true,
      acknowledgements: bookmark.tombstoneAckedByDeviceIds,
      deviceId: localDeviceId,
    ),
  );
}

List<String> _acknowledgeIfDeleted({
  required bool deleted,
  required List<String> acknowledgements,
  required String deviceId,
}) {
  if (!deleted) return const [];
  final result = <String>{...acknowledgements};
  if (deviceId.trim().isNotEmpty) result.add(deviceId);
  return result.toList()..sort();
}

bool tombstoneAcknowledgedByAllTrustedDevices({
  required Iterable<String> acknowledgedDeviceIds,
  required Iterable<TrustedDeviceRecord> trustedDevices,
}) {
  final acknowledgements = acknowledgedDeviceIds.toSet();
  return trustedDevices
      .where((device) => !device.isRevoked)
      .every((device) => acknowledgements.contains(device.deviceId));
}

List<TrustedDeviceRecord> _mergeTrustedDevices(List<TrustedDeviceRecord> local, List<TrustedDeviceRecord> remote) {
  final byId = <String, TrustedDeviceRecord>{};
  for (final device in [...local, ...remote]) {
    final existing = byId[device.deviceId];
    if (existing == null) {
      byId[device.deviceId] = device;
      continue;
    }
    if (existing.isRevoked != device.isRevoked) {
      if (device.isRevoked) byId[device.deviceId] = device;
      continue;
    }
    final existingMarker = existing.deletedAt ?? existing.lastSeenAt;
    final deviceMarker = device.deletedAt ?? device.lastSeenAt;
    if (deviceMarker.isAfter(existingMarker)) byId[device.deviceId] = device;
  }
  return byId.values.toList()..sort((a, b) {
    if (a.isDeleted != b.isDeleted) return a.isDeleted ? 1 : -1;
    final ownerCompare = (b.role == 'owner' ? 1 : 0).compareTo(a.role == 'owner' ? 1 : 0);
    if (ownerCompare != 0) return ownerCompare;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
}

DateTime _latest(DateTime a, DateTime b) => a.isAfter(b) ? a : b;
