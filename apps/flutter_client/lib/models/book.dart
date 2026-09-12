import 'package:uuid/uuid.dart';

import 'sync_revision.dart';

const _uuid = Uuid();

enum BookDownloadStatus { downloaded, remoteOnly, missingLocalFile }

class BookmarkRecord {
  BookmarkRecord({
    String? id,
    required this.bookId,
    required this.label,
    required this.locator,
    this.note,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.deletedAt,
    this.revision = SyncRevision.zero,
    List<String>? tombstoneAckedByDeviceIds,
  }) : id = id ?? _uuid.v4(),
       createdAt = createdAt ?? DateTime.now().toUtc(),
       updatedAt = updatedAt ?? DateTime.now().toUtc(),
       tombstoneAckedByDeviceIds = _uniqueStrings(tombstoneAckedByDeviceIds ?? const []);

  final String id;
  final String bookId;
  final String label;
  final String locator;
  final String? note;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;
  final SyncRevision revision;
  final List<String> tombstoneAckedByDeviceIds;

  bool get isDeleted => deletedAt != null;

  BookmarkRecord copyWith({
    String? label,
    String? locator,
    String? note,
    DateTime? updatedAt,
    DateTime? deletedAt,
    SyncRevision? revision,
    List<String>? tombstoneAckedByDeviceIds,
  }) {
    return BookmarkRecord(
      id: id,
      bookId: bookId,
      label: label ?? this.label,
      locator: locator ?? this.locator,
      note: note ?? this.note,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now().toUtc(),
      deletedAt: deletedAt ?? this.deletedAt,
      revision: revision ?? this.revision,
      tombstoneAckedByDeviceIds: tombstoneAckedByDeviceIds ?? this.tombstoneAckedByDeviceIds,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'bookId': bookId,
    'label': label,
    'locator': locator,
    'note': note,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'deletedAt': deletedAt?.toIso8601String(),
    'revision': revision.toJson(),
    'tombstoneAckedByDeviceIds': tombstoneAckedByDeviceIds,
  };

  factory BookmarkRecord.fromJson(Map<String, dynamic> json) => BookmarkRecord(
    id: json['id'] as String,
    bookId: json['bookId'] as String,
    label: json['label'] as String? ?? 'Закладка',
    locator: json['locator'] as String? ?? '',
    note: json['note'] as String?,
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now().toUtc(),
    updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? DateTime.now().toUtc(),
    deletedAt: json['deletedAt'] == null ? null : DateTime.tryParse(json['deletedAt'] as String),
    revision: SyncRevision.fromJson(json['revision'], legacyDeviceId: json['updatedByDeviceId']?.toString() ?? ''),
    tombstoneAckedByDeviceIds: ((json['tombstoneAckedByDeviceIds'] as List?) ?? const [])
        .map((item) => item.toString())
        .toList(),
  );
}

class BookRecord {
  BookRecord({
    required this.id,
    required this.title,
    required this.fileName,
    required this.format,
    required this.sizeBytes,
    required this.contentSha256,
    this.localPath,
    this.relativeLocation,
    this.sourceAvailability = 'unavailable',
    DateTime? addedAt,
    DateTime? updatedAt,
    this.progressPercent = 0,
    this.currentLocator = '',
    this.progressVersion = 0,
    this.updatedByDeviceId = 'local-device',
    this.deletedAt,
    List<String>? availableOnDeviceIds,
    List<BookmarkRecord>? bookmarks,
    this.metadataRevision = SyncRevision.zero,
    SyncRevision? progressRevision,
    List<String>? tombstoneAckedByDeviceIds,
  }) : addedAt = addedAt ?? DateTime.now().toUtc(),
       updatedAt = updatedAt ?? DateTime.now().toUtc(),
       availableOnDeviceIds = _uniqueStrings(availableOnDeviceIds ?? const []),
       bookmarks = bookmarks ?? [],
       progressRevision = progressRevision ?? SyncRevision(counter: progressVersion, deviceId: updatedByDeviceId),
       tombstoneAckedByDeviceIds = _uniqueStrings(tombstoneAckedByDeviceIds ?? const []);

  final String id;
  final String title;
  final String fileName;
  final String format;
  final int sizeBytes;
  final String contentSha256;

  /// Path is intentionally local-only. It must never be trusted from another
  /// device. Remote snapshots carry [availableOnDeviceIds] instead.
  final String? localPath;

  /// Logical location under the user-selected library root. It is local
  /// metadata, never an absolute path or a platform URI, and is stripped from
  /// cross-device snapshots because every device may organize its own root.
  final String? relativeLocation;

  /// Distinguishes a locally readable source from a File Provider item whose
  /// bytes need materialization. Values mirror LibraryEntryAvailability names
  /// without coupling the domain model to platform storage APIs.
  final String sourceAvailability;

  final DateTime addedAt;
  final DateTime updatedAt;
  final double progressPercent;
  final String currentLocator;
  final int progressVersion;
  final String updatedByDeviceId;
  final DateTime? deletedAt;
  final List<String> availableOnDeviceIds;
  final List<BookmarkRecord> bookmarks;
  final SyncRevision metadataRevision;
  final SyncRevision progressRevision;
  final List<String> tombstoneAckedByDeviceIds;

  bool get isDeleted => deletedAt != null;
  bool get hasLocalSource =>
      !isDeleted &&
      ((relativeLocation != null && relativeLocation!.isNotEmpty) || (localPath != null && localPath!.isNotEmpty));
  bool get isDownloaded => hasLocalSource;
  bool get isOfflineAvailable => hasLocalSource && sourceAvailability == 'available';
  List<BookmarkRecord> get visibleBookmarks => bookmarks.where((bookmark) => !bookmark.isDeleted).toList();

  BookDownloadStatus get downloadStatus => isDownloaded ? BookDownloadStatus.downloaded : BookDownloadStatus.remoteOnly;

  bool isAvailableOnDevice(String deviceId) => availableOnDeviceIds.contains(deviceId);

  BookRecord copyWith({
    String? title,
    String? fileName,
    String? format,
    int? sizeBytes,
    String? contentSha256,
    String? localPath,
    bool clearLocalPath = false,
    String? relativeLocation,
    bool clearRelativeLocation = false,
    String? sourceAvailability,
    DateTime? updatedAt,
    double? progressPercent,
    String? currentLocator,
    int? progressVersion,
    String? updatedByDeviceId,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
    List<String>? availableOnDeviceIds,
    List<BookmarkRecord>? bookmarks,
    SyncRevision? metadataRevision,
    SyncRevision? progressRevision,
    List<String>? tombstoneAckedByDeviceIds,
  }) {
    return BookRecord(
      id: id,
      title: title ?? this.title,
      fileName: fileName ?? this.fileName,
      format: format ?? this.format,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      contentSha256: contentSha256 ?? this.contentSha256,
      localPath: clearLocalPath ? null : (localPath ?? this.localPath),
      relativeLocation: clearRelativeLocation ? null : (relativeLocation ?? this.relativeLocation),
      sourceAvailability: sourceAvailability ?? this.sourceAvailability,
      addedAt: addedAt,
      updatedAt: updatedAt ?? DateTime.now().toUtc(),
      progressPercent: progressPercent ?? this.progressPercent,
      currentLocator: currentLocator ?? this.currentLocator,
      progressVersion: progressVersion ?? this.progressVersion,
      updatedByDeviceId: updatedByDeviceId ?? this.updatedByDeviceId,
      deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
      availableOnDeviceIds: availableOnDeviceIds ?? this.availableOnDeviceIds,
      bookmarks: bookmarks ?? this.bookmarks,
      metadataRevision: metadataRevision ?? this.metadataRevision,
      progressRevision: progressRevision ?? this.progressRevision,
      tombstoneAckedByDeviceIds: tombstoneAckedByDeviceIds ?? this.tombstoneAckedByDeviceIds,
    );
  }

  Map<String, dynamic> toJson({bool includeLocalPath = true}) => {
    'id': id,
    'title': title,
    'fileName': fileName,
    'format': format,
    'sizeBytes': sizeBytes,
    'contentSha256': contentSha256,
    if (includeLocalPath) 'localPath': localPath,
    if (includeLocalPath) 'relativeLocation': relativeLocation,
    if (includeLocalPath) 'sourceAvailability': sourceAvailability,
    'addedAt': addedAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'progressPercent': progressPercent,
    'currentLocator': currentLocator,
    'progressVersion': progressVersion,
    'updatedByDeviceId': updatedByDeviceId,
    'deletedAt': deletedAt?.toIso8601String(),
    'availableOnDeviceIds': availableOnDeviceIds,
    'bookmarks': bookmarks.map((b) => b.toJson()).toList(),
    'metadataRevision': metadataRevision.toJson(),
    'progressRevision': progressRevision.toJson(),
    'tombstoneAckedByDeviceIds': tombstoneAckedByDeviceIds,
  };

  factory BookRecord.fromJson(Map<String, dynamic> json) => BookRecord(
    id: json['id'] as String,
    title: json['title'] as String? ?? 'Без названия',
    fileName: json['fileName'] as String? ?? '',
    format: json['format'] as String? ?? 'unknown',
    sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
    contentSha256: json['contentSha256'] as String? ?? json['id'] as String,
    localPath: json['localPath'] as String?,
    relativeLocation: json['relativeLocation'] as String?,
    sourceAvailability:
        json['sourceAvailability'] as String? ??
        ((json['localPath'] as String?)?.isNotEmpty == true ? 'available' : 'unavailable'),
    addedAt: DateTime.tryParse(json['addedAt'] as String? ?? '') ?? DateTime.now().toUtc(),
    updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? DateTime.now().toUtc(),
    progressPercent: (json['progressPercent'] as num?)?.toDouble() ?? 0,
    currentLocator: json['currentLocator'] as String? ?? '',
    progressVersion: (json['progressVersion'] as num?)?.toInt() ?? 0,
    updatedByDeviceId: json['updatedByDeviceId'] as String? ?? 'unknown',
    deletedAt: json['deletedAt'] == null ? null : DateTime.tryParse(json['deletedAt'] as String),
    availableOnDeviceIds: ((json['availableOnDeviceIds'] as List?) ?? []).map((item) => item.toString()).toList(),
    bookmarks: ((json['bookmarks'] as List?) ?? [])
        .map((item) => BookmarkRecord.fromJson(item as Map<String, dynamic>))
        .toList(),
    metadataRevision: SyncRevision.fromJson(
      json['metadataRevision'],
      legacyDeviceId: json['updatedByDeviceId']?.toString() ?? '',
    ),
    progressRevision: SyncRevision.fromJson(
      json['progressRevision'],
      legacyCounter: (json['progressVersion'] as num?)?.toInt() ?? 0,
      legacyDeviceId: json['updatedByDeviceId']?.toString() ?? '',
    ),
    tombstoneAckedByDeviceIds: ((json['tombstoneAckedByDeviceIds'] as List?) ?? const [])
        .map((item) => item.toString())
        .toList(),
  );
}

int compareBooksForLibrary(BookRecord a, BookRecord b) {
  final titleCompare = a.title.toLowerCase().compareTo(b.title.toLowerCase());
  if (titleCompare != 0) return titleCompare;
  final authorlessFileCompare = a.fileName.toLowerCase().compareTo(b.fileName.toLowerCase());
  if (authorlessFileCompare != 0) return authorlessFileCompare;
  final addedCompare = a.addedAt.compareTo(b.addedAt);
  if (addedCompare != 0) return addedCompare;
  return a.id.compareTo(b.id);
}

List<BookRecord> sortBooksForLibrary(Iterable<BookRecord> books) {
  return books.where((book) => !book.isDeleted).toList()..sort(compareBooksForLibrary);
}

List<String> _uniqueStrings(List<String> items) {
  return items.where((item) => item.trim().isNotEmpty).toSet().toList()..sort();
}
