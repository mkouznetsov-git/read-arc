import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../models/book.dart';
import '../../models/manifest.dart';
import '../../models/sync_settings.dart';
import '../storage_service.dart';
import 'connection_manager.dart';
import 'direct_transfer_server.dart';
import 'e2e_crypto.dart';
import 'file_transfer_manager.dart';
import 'metadata_sync_engine.dart';
import 'pairing_service.dart';
import 'relay_client.dart';
import 'sync_authorization.dart';

const _uuid = Uuid();
const _defaultChunkSize = 1024 * 1024; // Binary chunks: 1 MiB keeps Tailscale/Android stable and reduces ACK overhead.
const _downloadOfferTimeout = Duration(seconds: 24);
const _downloadIdleTimeout = Duration(seconds: 28);
const _directStreamIdleTimeout = Duration(seconds: 18);

class FileTransferChunkCheckpoint {
  const FileTransferChunkCheckpoint({
    required this.transferId,
    required this.bookId,
    required this.chunkIndex,
    required this.receivedBytes,
  });

  final String transferId;
  final String bookId;
  final int chunkIndex;
  final int receivedBytes;
}

typedef FileTransferFaultInjector = bool Function(FileTransferChunkCheckpoint checkpoint);
typedef BeforeSendingFileChunk = Future<void> Function(FileTransferChunkCheckpoint checkpoint);

class PairingInvite {
  const PairingInvite({
    required this.code,
    required this.relayUrl,
    required this.expiresAt,
    required this.inviteLink,
    required this.ownerDeviceName,
    required this.accountEncryptionKey,
  });

  final String code;
  final String relayUrl;
  final DateTime expiresAt;
  final String inviteLink;
  final String ownerDeviceName;
  final String accountEncryptionKey;

  String get displayCode => code;

  bool get isExpired => DateTime.now().toUtc().isAfter(expiresAt);

  bool get isNearExpiry => DateTime.now().toUtc().add(const Duration(seconds: 20)).isAfter(expiresAt);
}

class PairingClaimResult {
  const PairingClaimResult({
    required this.accountId,
    required this.relayUrl,
    required this.ownerDeviceId,
    required this.ownerDeviceName,
    required this.accountEncryptionKey,
  });

  final String accountId;
  final String relayUrl;
  final String ownerDeviceId;
  final String ownerDeviceName;
  final String accountEncryptionKey;
}

class _ParsedPairingInput {
  const _ParsedPairingInput({
    required this.code,
    this.relayUrl,
    this.accountEncryptionKey,
    this.ownerDeviceName,
    this.ownerDevicePublicKey,
    this.accountId,
    this.ownerDeviceId,
    this.expiresAt,
  });

  final String code;
  final String? relayUrl;
  final String? accountEncryptionKey;
  final String? ownerDeviceName;
  final String? ownerDevicePublicKey;
  final String? accountId;
  final String? ownerDeviceId;
  final DateTime? expiresAt;

  bool get hasEmbeddedAccountInvite =>
      (accountId?.isNotEmpty ?? false) &&
      (ownerDeviceId?.isNotEmpty ?? false) &&
      (accountEncryptionKey?.isNotEmpty ?? false);

  bool get embeddedInviteExpired => expiresAt != null && DateTime.now().toUtc().isAfter(expiresAt!);
}

class FileTransferSnapshot {
  const FileTransferSnapshot({
    required this.transferId,
    required this.bookId,
    required this.direction,
    required this.statusText,
    this.fileName = '',
    this.peerDeviceId = '',
    this.progressPercent = 0,
    this.transferredBytes = 0,
    this.totalBytes = 0,
    this.active = false,
    this.error,
  });

  final String transferId;
  final String bookId;
  final String direction; // download | upload
  final String statusText;
  final String fileName;
  final String peerDeviceId;
  final double progressPercent;
  final int transferredBytes;
  final int totalBytes;
  final bool active;
  final String? error;

  bool get hasError => error != null && error!.isNotEmpty;

  FileTransferSnapshot copyWith({
    String? statusText,
    String? fileName,
    String? peerDeviceId,
    double? progressPercent,
    int? transferredBytes,
    int? totalBytes,
    bool? active,
    String? error,
    bool clearError = false,
  }) {
    return FileTransferSnapshot(
      transferId: transferId,
      bookId: bookId,
      direction: direction,
      statusText: statusText ?? this.statusText,
      fileName: fileName ?? this.fileName,
      peerDeviceId: peerDeviceId ?? this.peerDeviceId,
      progressPercent: progressPercent ?? this.progressPercent,
      transferredBytes: transferredBytes ?? this.transferredBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      active: active ?? this.active,
      error: clearError ? null : error ?? this.error,
    );
  }
}

class SyncStateSnapshot {
  const SyncStateSnapshot({
    required this.connected,
    required this.statusText,
    this.relayUrl,
    this.sentEvents = 0,
    this.receivedEvents = 0,
    this.logLines = const [],
    this.fileTransfers = const {},
    this.onlinePeerDeviceIds = const [],
  });

  final bool connected;
  final String statusText;
  final String? relayUrl;
  final int sentEvents;
  final int receivedEvents;
  final List<String> logLines;
  final Map<String, FileTransferSnapshot> fileTransfers;
  final List<String> onlinePeerDeviceIds;

  SyncStateSnapshot copyWith({
    bool? connected,
    String? statusText,
    String? relayUrl,
    int? sentEvents,
    int? receivedEvents,
    List<String>? logLines,
    Map<String, FileTransferSnapshot>? fileTransfers,
    List<String>? onlinePeerDeviceIds,
  }) {
    return SyncStateSnapshot(
      connected: connected ?? this.connected,
      statusText: statusText ?? this.statusText,
      relayUrl: relayUrl ?? this.relayUrl,
      sentEvents: sentEvents ?? this.sentEvents,
      receivedEvents: receivedEvents ?? this.receivedEvents,
      logLines: logLines ?? this.logLines,
      fileTransfers: fileTransfers ?? this.fileTransfers,
      onlinePeerDeviceIds: onlinePeerDeviceIds ?? this.onlinePeerDeviceIds,
    );
  }

  FileTransferSnapshot? downloadForBook(String bookId) => fileTransfers[bookId];

  bool hasOnlineStorageFor(BookRecord book) {
    final online = onlinePeerDeviceIds.toSet();
    return book.availableOnDeviceIds.any(online.contains);
  }
}

class SyncService {
  SyncService(
    this._storage, {
    DirectTransferServer? directTransferServer,
    int fileChunkSize = _defaultChunkSize,
    Duration fileChunkAckTimeout = const Duration(seconds: 20),
    this.pauseAfterCommittedChunk,
    this.beforeSendingFileChunk,
  }) : assert(fileChunkSize >= 256 * 1024 && fileChunkSize <= _defaultChunkSize),
       assert(fileChunkAckTimeout > Duration.zero),
       _fileChunkSize = fileChunkSize,
       _fileChunkAckTimeout = fileChunkAckTimeout,
       _directTransferServer = directTransferServer ?? DirectTransferServer(),
       _metadataSyncEngine = MetadataSyncEngine(_storage),
       _fileTransferManager = FileTransferManager(appDirectory: _storage.appDir),
       _pairingService = PairingService(const ConnectionManager());

  final StorageService _storage;
  final MetadataSyncEngine _metadataSyncEngine;
  final FileTransferManager _fileTransferManager;
  final int _fileChunkSize;
  final Duration _fileChunkAckTimeout;
  final FileTransferFaultInjector? pauseAfterCommittedChunk;
  final BeforeSendingFileChunk? beforeSendingFileChunk;
  final ConnectionManager _connectionManager = const ConnectionManager();
  final PairingService _pairingService;
  final DirectTransferServer _directTransferServer;
  final SyncAuthorization _authorization = const SyncAuthorization();
  final state = ValueNotifier<SyncStateSnapshot>(
    const SyncStateSnapshot(connected: false, statusText: 'Не подключено'),
  );

  RelayClient? _client;
  StreamSubscription<void>? _incomingSubscription;
  StreamSubscription<void>? _binarySubscription;
  final _manifestChanges = StreamController<LibraryManifest>.broadcast();
  final _downloadsByTransferId = <String, _DownloadSession>{};
  final _uploadAckWaiters = <String, Completer<void>>{};
  final _uploadLocks = <String>{};
  final _cancelledTransfers = <String>{};
  final _seenSecureEventIds = <String, DateTime>{};
  // Sprint 27: relay can keep encrypted metadata events for offline devices.
  // Keep replay protection aligned with the relay TTL while still rejecting
  // duplicate eventIds inside the active window.
  static const _replayWindow = Duration(days: 30);

  Timer? _reconnectTimer;
  Timer? _healthTimer;
  Timer? _metadataRefreshTimer;
  bool _manualDisconnect = true;
  bool _reconnectInProgress = false;
  bool _relayUnavailableLogged = false;
  bool _disposed = false;
  int _reconnectAttempt = 0;
  int _healthMisses = 0;
  String? _lastRelayUrl;

  Stream<LibraryManifest> get manifestChanges => _manifestChanges.stream;

  /// Start persistent reconnect loop without requiring the first connection to
  /// succeed. This is used on app startup when autoConnect=true and the
  /// Personal Hub/relay is still offline.
  void startAutoReconnect({required String relayUrl}) {
    if (_disposed) return;
    if (relayUrl.trim().isEmpty || _manualDisconnect == false && _lastRelayUrl == relayUrl && _reconnectTimer != null) {
      return;
    }
    _manualDisconnect = false;
    _lastRelayUrl = relayUrl;
    _reconnectAttempt = 0;
    _appendRelayUnavailableLogOnce();
    _setState(
      state.value.copyWith(connected: false, relayUrl: relayUrl, statusText: 'Relay недоступен. Переподключаемся...'),
    );
    _scheduleReconnect(immediate: true);
  }

  Future<void> connect({required String relayUrl}) async {
    if (_disposed) throw StateError('SyncService уже остановлен');
    _manualDisconnect = false;
    _lastRelayUrl = relayUrl;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await disconnect(manual: false);
    _setState(state.value.copyWith(connected: false, statusText: 'Подключение...', relayUrl: relayUrl));

    final manifest = await _storage.loadManifest();
    if (manifest.isCurrentDeviceRevoked) {
      _setState(
        state.value.copyWith(connected: false, statusText: 'Доступ этого устройства отозван', relayUrl: relayUrl),
      );
      throw StateError('Доступ этого устройства к аккаунту отозван');
    }
    await _probeRelayHealth(relayUrl, timeout: const Duration(seconds: 5));
    final uri = Uri.parse(relayUrl.trim());
    final client = _connectionManager.createClient(relayUri: uri, manifest: manifest);
    _client = client;
    _incomingSubscription = client.incoming
        .asyncMap((envelope) async {
          await _handleIncomingEnvelope(envelope);
        })
        .listen(
          (_) {},
          onError: (error) {
            unawaited(_handleRelayDisconnected(error));
          },
        );
    _binarySubscription = client.binaryIncoming
        .asyncMap((message) async {
          await _handleIncomingBinaryFrame(message);
        })
        .listen(
          (_) {},
          onError: (error) {
            unawaited(_handleRelayDisconnected(error));
          },
        );

    try {
      await client.connect();
    } catch (error) {
      await disconnect(manual: false);
      if (!_reconnectInProgress) {
        _appendRelayUnavailableLogOnce();
        _scheduleReconnect();
      }
      rethrow;
    }
    _reconnectAttempt = 0;
    _healthMisses = 0;
    _relayUnavailableLogged = false;
    _appendLog('Подключено к $relayUrl');
    _setState(state.value.copyWith(connected: true, statusText: 'Подключено'));
    _startHealthMonitor(relayUrl);
    _startMetadataRefreshLoop(client);
    unawaited(_ensureDirectFileServer());

    await pullOfflineQueue(reason: 'connected');
    await refreshMetadata(reason: 'connected');
    _scheduleStartupMetadataRefresh(client);
    unawaited(_resumePendingTransfers());
  }

  Future<void> disconnect({bool manual = true}) async {
    _pauseActiveDownloads(
      statusText: manual
          ? 'Передача приостановлена. После подключения скачивание продолжится.'
          : 'Соединение прервано. После reconnect скачивание продолжится.',
    );
    _healthTimer?.cancel();
    _healthTimer = null;
    _metadataRefreshTimer?.cancel();
    _metadataRefreshTimer = null;
    if (manual) _healthMisses = 0;
    if (manual) {
      _manualDisconnect = true;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
    }
    await _incomingSubscription?.cancel();
    _incomingSubscription = null;
    await _binarySubscription?.cancel();
    _binarySubscription = null;
    final client = _client;
    _client = null;
    await client?.dispose();
    if (manual && state.value.connected) {
      _appendLog('Отключено');
    }
    _setState(
      state.value.copyWith(
        connected: false,
        statusText: manual ? 'Не подключено' : 'Relay недоступен. Переподключаемся...',
        onlinePeerDeviceIds: const [],
      ),
    );
  }

  Future<void> _handleRelayDisconnected(Object error) async {
    if (_manualDisconnect) return;
    await disconnect(manual: false);
    _appendRelayUnavailableLogOnce();
    _scheduleReconnect();
  }

  void _scheduleReconnect({bool immediate = false}) {
    if (_manualDisconnect || _reconnectInProgress) return;
    final relayUrl = _lastRelayUrl;
    if (relayUrl == null || relayUrl.trim().isEmpty) return;
    _reconnectTimer?.cancel();
    final seconds = immediate ? 0 : _reconnectDelaySeconds(_reconnectAttempt);
    _setState(
      state.value.copyWith(
        connected: false,
        statusText: seconds <= 0 ? 'Relay недоступен. Переподключаемся...' : 'Relay недоступен. Повтор через $secondsс',
        relayUrl: relayUrl,
      ),
    );
    _reconnectTimer = Timer(Duration(seconds: seconds), () {
      unawaited(_attemptReconnect(relayUrl));
    });
  }

  int _reconnectDelaySeconds(int attempt) => _connectionManager.retryDelaySeconds(attempt);

  void _appendRelayUnavailableLogOnce() {
    if (_relayUnavailableLogged) return;
    _relayUnavailableLogged = true;
    _appendLog('Relay недоступен. Автопереподключение включено.');
  }

  void _startHealthMonitor(String relayUrl) {
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_checkRelayHealth(relayUrl));
    });
  }

  Future<void> _checkRelayHealth(String relayUrl) async {
    if (_manualDisconnect || !state.value.connected) return;
    try {
      await _probeRelayHealth(relayUrl, timeout: const Duration(seconds: 5));
      if (_healthMisses != 0) {
        _healthMisses = 0;
        _setState(state.value.copyWith(statusText: 'Подключено'));
      }
    } catch (error) {
      _healthMisses += 1;
      // A single failed HTTP probe does not mean the websocket relay is down:
      // mobile radios, DNS caches and captive network transitions can drop one
      // request while the relay itself is healthy. Disconnect only after a few
      // consecutive misses.
      if (_healthMisses < 3) {
        _setState(state.value.copyWith(statusText: 'Подключено. Проверяем relay...'));
        return;
      }
      await _handleRelayDisconnected(error);
    }
  }

  Future<void> _probeRelayHealth(String relayUrl, {required Duration timeout}) =>
      _connectionManager.probeHealth(relayUrl, timeout: timeout);

  Future<void> _attemptReconnect(String relayUrl) async {
    if (_manualDisconnect || _reconnectInProgress) return;
    _reconnectInProgress = true;
    try {
      _reconnectAttempt += 1;
      await connect(relayUrl: relayUrl);
      _appendLog('Автопереподключение выполнено');
    } catch (_) {
      // Не пишем каждую неудачную попытку в журнал: иначе он быстро
      // превращается в шум при выключенном hub/relay. Текущий статус
      // виден по иконке и строке состояния.
      _reconnectInProgress = false;
      _scheduleReconnect();
      return;
    }
    _reconnectInProgress = false;
  }

  Future<void> refreshMetadata({required String reason}) async {
    await requestLibrarySnapshot(reason: '$reason/request');
    await broadcastLibrarySnapshot(reason: '$reason/snapshot');
  }

  void _scheduleStartupMetadataRefresh(RelayClient client) {
    for (final delay in const [Duration(milliseconds: 600), Duration(seconds: 2), Duration(seconds: 5)]) {
      unawaited(
        Future<void>.delayed(delay, () async {
          if (_disposed || _client != client || !state.value.connected) return;
          await pullOfflineQueue(reason: 'startup_retry_${delay.inMilliseconds}ms');
          await refreshMetadata(reason: 'startup_retry_${delay.inMilliseconds}ms');
        }),
      );
    }
  }

  void _startMetadataRefreshLoop(RelayClient client) {
    _metadataRefreshTimer?.cancel();
    _metadataRefreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_client != client || !state.value.connected || _manualDisconnect) return;
      // Sprint 43 Sync v2: periodic health/queue maintenance must not spam peers
      // with snapshot requests. Repeated requests can resurrect stale queued
      // metadata from just-paired or empty devices and make the UI look as if the
      // library was lost. Snapshot requests remain explicit: on connect, after
      // pairing, and after a guarded/destructive snapshot is rejected.
      unawaited(pullOfflineQueue(reason: 'periodic'));
    });
  }

  Future<bool> pullOfflineQueue({required String reason}) async {
    final client = _client;
    if (client == null || !state.value.connected) return false;
    try {
      client.sendControl({
        'type': 'offline_queue_pull',
        'accountId': client.accountId,
        'deviceId': client.deviceId,
        'payload': {'reason': reason},
      });
      return true;
    } catch (error) {
      _appendLog('Не удалось запросить offline queue: $error');
      return false;
    }
  }

  Future<bool> broadcastLibrarySnapshot({required String reason}) async {
    final client = _client;
    if (client == null || !state.value.connected) return false;

    final manifest = await _storage.touchCurrentDevice();
    if (reason.contains('trusted_device_revoked')) {
      _directTransferServer.revokeAllShares();
    }
    final envelope = SyncEnvelope(
      type: 'library_snapshot',
      accountId: manifest.accountId,
      deviceId: manifest.deviceId,
      payload: {'reason': reason, 'manifest': manifest.toSyncJson()},
    );

    final sent = await _sendEnvelope(envelope, logLabel: 'Отправлен E2E snapshot: $reason');
    if (_shouldRetrySnapshotBroadcast(reason)) {
      _scheduleSnapshotBroadcastRetries(reason: reason);
    }
    return sent;
  }

  bool _shouldRetrySnapshotBroadcast(String reason) {
    if (reason.contains('_retry_')) return false;
    return reason.contains('book_imported') ||
        reason.contains('local_copy_removed') ||
        reason.contains('book_deleted') ||
        reason.contains('trusted_device_revoked') ||
        reason.contains('pairing_claimed') ||
        reason.contains('device_name_changed');
  }

  void _scheduleSnapshotBroadcastRetries({required String reason}) {
    for (final delay in const [Duration(seconds: 2), Duration(seconds: 8)]) {
      unawaited(
        Future<void>.delayed(delay, () async {
          if (_disposed || !state.value.connected || _manualDisconnect) return;
          await broadcastLibrarySnapshot(reason: '${reason}_retry_${delay.inSeconds}s');
        }),
      );
    }
  }

  Future<bool> requestLibrarySnapshot({required String reason}) async {
    final manifest = await _storage.loadManifest();
    return _sendEnvelope(
      SyncEnvelope(
        type: 'library_snapshot_requested',
        accountId: manifest.accountId,
        deviceId: manifest.deviceId,
        payload: {'reason': reason, 'requestingDeviceId': manifest.deviceId},
      ),
      logLabel: 'Запрошен snapshot: $reason',
    );
  }

  Future<PairingInvite> createPairingInvite({
    required SyncSettings settings,
    Duration ttl = const Duration(minutes: 5),
  }) async {
    _validateEndpointForPairing(settings);
    final manifest = await _storage.loadManifest();
    final uri = _buildEndpointUri(settings.effectiveRelayUrl, '/pairing/start');
    final response = await _postJson(uri, {
      'accountId': manifest.accountId,
      'ownerDeviceId': manifest.deviceId,
      'ownerDeviceName': manifest.deviceName,
      'ownerDevicePublicKey': manifest.deviceSigningPublicKey,
      // The short-code pairing flow stores the one-time invite payload on the
      // official relay until it is claimed or expires.
      'accountEncryptionKey': manifest.accountEncryptionKey,
      'relayUrl': settings.effectiveRelayUrl,
      'expiresSeconds': ttl.inSeconds,
    });
    if (response['ok'] != true) {
      throw StateError(response['message']?.toString() ?? 'Relay не создал pairing-код');
    }
    final code = _normalizePairingCode(response['code']?.toString() ?? '');
    if (code.length != 6) {
      throw StateError('Relay вернул некорректный pairing-код');
    }
    final expiresAtSeconds = (response['expiresAt'] as num?)?.toDouble();
    final expiresAt = expiresAtSeconds == null
        ? DateTime.now().toUtc().add(ttl)
        : DateTime.fromMillisecondsSinceEpoch((expiresAtSeconds * 1000).round(), isUtc: true);
    // QR and manual entry now carry only the short one-time code. The relay
    // stores the full invite payload for a few minutes and returns it from
    // /pairing/claim, so users do not have to scan/type long unreadable links.
    final inviteLink = code;
    _appendLog('Создан pairing-код $code');
    return PairingInvite(
      code: code,
      relayUrl: settings.effectiveRelayUrl,
      expiresAt: expiresAt,
      inviteLink: inviteLink,
      ownerDeviceName: manifest.deviceName,
      accountEncryptionKey: manifest.accountEncryptionKey,
    );
  }

  Future<PairingClaimResult> claimPairingInvite({required String input, required SyncSettings fallbackSettings}) async {
    final parsed = _parsePairingInput(input);
    final effectiveSettings = _settingsForClaimedRelayUrl(
      parsed.relayUrl ?? fallbackSettings.effectiveRelayUrl,
      fallbackSettings,
    );
    _validateEndpointForPairing(effectiveSettings);
    final relayUrl = effectiveSettings.effectiveRelayUrl;

    var local = await _storage.loadManifest();
    if (local.isCurrentDeviceRevoked) {
      local = await _storage.rotateCurrentDeviceIdentityForPairing();
      _appendLog('Создана новая идентичность устройства для повторного подключения после отзыва доступа.');
    }

    final uri = _buildEndpointUri(relayUrl, '/pairing/claim');
    Map<String, dynamic>? response;
    Object? claimError;
    try {
      response = await _postJson(uri, {
        'code': parsed.code,
        'deviceId': local.deviceId,
        'deviceName': local.deviceName,
        'devicePublicKey': local.deviceSigningPublicKey,
      });
      if (response['ok'] != true) {
        throw StateError(response['message']?.toString() ?? 'Pairing-код не принят relay');
      }
    } catch (error) {
      claimError = error;
      if (!parsed.hasEmbeddedAccountInvite || parsed.embeddedInviteExpired) {
        rethrow;
      }
      _appendLog('Relay не принял короткий код: $error');
    }

    final accountId = response?['accountId']?.toString() ?? parsed.accountId ?? '';
    final ownerDeviceId = response?['ownerDeviceId']?.toString() ?? parsed.ownerDeviceId ?? '';
    final ownerDeviceName = response?['ownerDeviceName']?.toString() ?? parsed.ownerDeviceName ?? 'Устройство';
    final ownerDevicePublicKey = response?['ownerDevicePublicKey']?.toString() ?? parsed.ownerDevicePublicKey ?? '';
    final accountEncryptionKey = parsed.accountEncryptionKey ?? response?['accountEncryptionKey']?.toString() ?? '';
    final returnedRelayUrl = relayUrl;
    if (accountId.isEmpty || ownerDeviceId.isEmpty) {
      throw StateError('Relay вернул неполные pairing-данные${claimError == null ? '' : ': $claimError'}');
    }
    if (accountEncryptionKey.isEmpty) {
      throw StateError('В приглашении нет ключа шифрования аккаунта');
    }

    await disconnect(manual: false);
    await _storage.saveSyncSettings(
      _settingsForClaimedRelayUrl(returnedRelayUrl, fallbackSettings).copyWith(autoConnect: true),
    );
    await _storage.replaceAccountFromPairing(
      accountId: accountId,
      accountEncryptionKey: accountEncryptionKey,
      ownerDeviceId: ownerDeviceId,
      ownerDeviceName: ownerDeviceName,
      ownerDevicePublicKey: ownerDevicePublicKey,
    );
    _appendLog('Pairing выполнен. Аккаунт подключён автоматически.');
    await connect(relayUrl: relayUrl);
    await refreshMetadata(reason: 'pairing_completed');
    return PairingClaimResult(
      accountId: accountId,
      relayUrl: relayUrl,
      ownerDeviceId: ownerDeviceId,
      ownerDeviceName: ownerDeviceName,
      accountEncryptionKey: accountEncryptionKey,
    );
  }

  void _validateEndpointForPairing(SyncSettings settings) => _pairingService.validateEndpoint(settings);

  Uri _buildEndpointUri(String relayUrl, String endpointPath) => _pairingService.endpointUri(relayUrl, endpointPath);

  Future<Map<String, dynamic>> _postJson(Uri uri, Map<String, dynamic> body) => _pairingService.postJson(uri, body);

  _ParsedPairingInput _parsePairingInput(String input) {
    final raw = input.trim();
    if (raw.isEmpty) {
      throw ArgumentError('Введите pairing-код или приглашение');
    }
    if (raw.startsWith('readarc://')) {
      final uri = Uri.parse(raw);
      final code = _normalizePairingCode(uri.queryParameters['code'] ?? '');
      final relay = uri.queryParameters['relay']?.trim();
      final accountKey = uri.queryParameters['key']?.trim();
      final ownerDeviceName = uri.queryParameters['deviceName']?.trim();
      final ownerDevicePublicKey = uri.queryParameters['ownerDevicePublicKey']?.trim();
      final accountId = uri.queryParameters['accountId']?.trim();
      final ownerDeviceId = uri.queryParameters['ownerDeviceId']?.trim();
      final expiresAtRaw = uri.queryParameters['expiresAt']?.trim();
      final expiresAt = expiresAtRaw == null || expiresAtRaw.isEmpty ? null : DateTime.tryParse(expiresAtRaw)?.toUtc();
      if (code.length != 6) {
        throw ArgumentError('В приглашении нет корректного 6-значного кода');
      }
      return _ParsedPairingInput(
        code: code,
        relayUrl: relay?.isEmpty == true ? null : relay,
        accountEncryptionKey: accountKey?.isEmpty == true ? null : accountKey,
        ownerDeviceName: ownerDeviceName?.isEmpty == true ? null : ownerDeviceName,
        ownerDevicePublicKey: ownerDevicePublicKey?.isEmpty == true ? null : ownerDevicePublicKey,
        accountId: accountId?.isEmpty == true ? null : accountId,
        ownerDeviceId: ownerDeviceId?.isEmpty == true ? null : ownerDeviceId,
        expiresAt: expiresAt,
      );
    }
    final code = _normalizePairingCode(raw);
    if (code.length != 6) {
      throw ArgumentError('Код приглашения должен состоять из 6 цифр');
    }
    return _ParsedPairingInput(code: code);
  }

  String _normalizePairingCode(String raw) => raw.replaceAll(RegExp(r'[^0-9]'), '');

  SyncSettings _settingsForClaimedRelayUrl(String relayUrl, SyncSettings fallback) {
    // Sprint 25: all client connections use the official ReadArc relay.
    // Older QR links may still carry a custom/Tailscale relay parameter; keep
    // accepting the link but ignore that endpoint for the actual connection.
    return fallback.asOfficial(autoConnect: true);
  }

  Future<bool> requestBookFile(BookRecord book) async {
    final client = _client;
    if (client == null || !state.value.connected) {
      _appendLog('Нельзя скачать ${book.title}: нет подключения к relay');
      return false;
    }
    if (book.isDeleted) {
      _appendLog('${book.title} удалена из библиотеки');
      return false;
    }
    if (book.isDownloaded) {
      _appendLog('${book.title} уже скачана на этом устройстве');
      return false;
    }

    final manifest = await _storage.loadManifest();
    final transferId = 'transfer-${_uuid.v4()}';
    final session = _DownloadSession(
      transferId: transferId,
      bookId: book.id,
      fileName: book.fileName,
      format: book.format,
      expectedSha256: book.contentSha256,
      expectedBytes: book.sizeBytes,
    );
    await _fileTransferManager.prepare(
      PendingFileTransfer(
        transferId: transferId,
        bookId: book.id,
        fileName: book.fileName,
        format: book.format,
        expectedSha256: book.contentSha256,
        expectedBytes: book.sizeBytes,
        chunkSize: _fileChunkSize,
      ),
    );
    _downloadsByTransferId[transferId] = session;
    _setDownloadSnapshot(
      FileTransferSnapshot(
        transferId: transferId,
        bookId: book.id,
        direction: 'download',
        fileName: book.fileName,
        statusText: 'Ищем устройство с файлом...',
        active: true,
        totalBytes: book.sizeBytes,
      ),
    );

    // Requests can be lost exactly while a mobile client or Tailscale Funnel is
    // reconnecting. Send the same idempotent request a few times until an offer
    // is received, then fail with a clear reason instead of hanging silently.
    Future<bool> sendRequest({String? label}) => _sendEnvelope(
      SyncEnvelope(
        type: 'book_file_requested',
        accountId: manifest.accountId,
        deviceId: manifest.deviceId,
        payload: {
          'transferId': transferId,
          'bookId': book.id,
          'requestingDeviceId': manifest.deviceId,
          'fileName': book.fileName,
          'expectedSha256': book.contentSha256,
          'expectedSizeBytes': book.sizeBytes,
          'preferredChunkSize': _fileChunkSize,
          'binaryTransfer': true,
        },
      ),
      logLabel: label,
    );

    for (final delay in const [Duration(seconds: 5), Duration(seconds: 12)]) {
      unawaited(
        Future<void>.delayed(delay, () async {
          final current = _downloadsByTransferId[transferId];
          if (current == null || current.sourceDeviceId != null) return;
          _setDownloadSnapshot(
            state.value
                .downloadForBook(current.bookId)!
                .copyWith(statusText: 'Повторяем поиск источника...', active: true),
          );
          await sendRequest();
        }),
      );
    }

    unawaited(
      Future<void>.delayed(_downloadOfferTimeout, () async {
        final current = _downloadsByTransferId[transferId];
        if (current == null) return;
        if (current.sourceDeviceId == null) {
          await _failDownload(current, 'Источник не найден: устройство с книгой не ответило');
        }
      }),
    );

    return sendRequest(label: 'Запрошен файл: ${book.title}');
  }

  Future<void> cancelBookFileDownload(String bookId) async {
    _DownloadSession? session;
    for (final candidate in _downloadsByTransferId.values) {
      if (candidate.bookId == bookId) {
        session = candidate;
        break;
      }
    }
    if (session == null) return;
    final manifest = await _storage.loadManifest();
    final sourceDeviceId = session.sourceDeviceId;
    _downloadsByTransferId.remove(session.transferId);
    await _fileTransferManager.discard(session.bookId);
    _setDownloadSnapshot(
      FileTransferSnapshot(
        transferId: session.transferId,
        bookId: session.bookId,
        direction: 'download',
        fileName: session.fileName,
        peerDeviceId: sourceDeviceId ?? '',
        statusText: 'Скачивание отменено',
        active: false,
        progressPercent: 0,
        totalBytes: session.expectedBytes,
      ),
    );
    if (sourceDeviceId != null) {
      await _sendEnvelope(
        SyncEnvelope(
          type: 'book_file_cancelled',
          accountId: manifest.accountId,
          deviceId: manifest.deviceId,
          payload: {
            'transferId': session.transferId,
            'bookId': session.bookId,
            'sourceDeviceId': sourceDeviceId,
            'requestingDeviceId': manifest.deviceId,
          },
        ),
      );
    }
    _appendLog('Скачивание отменено: ${session.fileName}');
  }

  Future<void> _handleIncomingEnvelope(SyncEnvelope envelope) async {
    var handled = false;
    try {
      await _handleIncomingEnvelopeUnsafe(envelope);
      handled = true;
    } catch (error, stackTrace) {
      // A malformed file-transfer event must never break metadata sync.
      debugPrint('Sync event handling failed: $error\n$stackTrace');
      _appendLog('Ошибка обработки ${envelope.type}: $error');
    } finally {
      if (handled) {
        _ackRelayQueueEnvelope(envelope);
      }
    }
  }

  void _ackRelayQueueEnvelope(SyncEnvelope envelope) {
    final cursor = envelope.relayQueueSeq;
    final client = _client;
    if (cursor == null || client == null || !state.value.connected) return;
    try {
      client.sendControl({
        'type': 'offline_queue_ack',
        'accountId': envelope.accountId,
        'deviceId': client.deviceId,
        'payload': {'cursor': cursor},
      });
    } catch (error) {
      _appendLog('Не удалось подтвердить offline queue: $error');
    }
  }

  Future<void> _handleIncomingEnvelopeUnsafe(SyncEnvelope envelope) async {
    final local = await _storage.loadManifest();
    if (envelope.accountId != local.accountId) {
      _appendLog('Пропущено событие другого аккаунта: ${envelope.accountId}');
      return;
    }
    if (envelope.deviceId == local.deviceId) return;

    if (envelope.type == 'peer_list') {
      final peers = ((envelope.payload['peers'] as List?) ?? const [])
          .map((item) => item.toString())
          .where((id) => id != local.deviceId)
          .toList();
      _setState(state.value.copyWith(onlinePeerDeviceIds: peers));
      _appendLog('Relay peers online: ${peers.length}');
      await refreshMetadata(reason: 'peer_list');
      return;
    }

    if (envelope.type == 'peer_joined') {
      final peers = {...state.value.onlinePeerDeviceIds, envelope.deviceId}.toList()..sort();
      _setState(state.value.copyWith(onlinePeerDeviceIds: peers));
      _appendLog('Подключилось другое устройство: ${envelope.deviceId}');
      await refreshMetadata(reason: 'peer_joined');
      return;
    }

    if (envelope.type == 'peer_left') {
      final peers = state.value.onlinePeerDeviceIds.where((id) => id != envelope.deviceId).toList()..sort();
      _setState(state.value.copyWith(onlinePeerDeviceIds: peers));
      _appendLog('Отключилось другое устройство: ${envelope.deviceId}');
      return;
    }

    if (envelope.type == 'pairing_claimed') {
      await _handlePairingClaimed(envelope, local);
      return;
    }

    if (envelope.type == 'error') {
      _appendLog('Relay вернул ошибку: ${envelope.payload['message'] ?? envelope.payload}');
      return;
    }

    try {
      _metadataSyncEngine.validateProtocol(envelope.protocolVersion);
    } on ProtocolCompatibilityException catch (error) {
      _appendLog('$error');
      return;
    }

    if (_isRevokedDevice(local, envelope.deviceId)) {
      _appendLog('Отклонено событие от отозванного устройства: ${envelope.deviceId}');
      return;
    }

    if (!_acceptSecureEnvelope(envelope)) {
      return;
    }

    final decryptedPayload = await ReadArcE2eCrypto.decryptPayload(
      encryptedPayload: envelope.payload,
      accountEncryptionKey: local.accountEncryptionKey,
      eventType: envelope.type,
      accountId: envelope.accountId,
      deviceId: envelope.deviceId,
      createdAt: envelope.createdAt,
    );
    final protectedSync = decryptedPayload.remove('_sync');
    if (protectedSync is Map) {
      final protectedVersion = (protectedSync['protocolVersion'] as num?)?.toInt();
      final protectedOperationId = protectedSync['operationId']?.toString();
      if (protectedVersion != envelope.protocolVersion || protectedOperationId != envelope.operationId) {
        _appendLog('Отклонено событие с изменёнными protocolVersion/operationId');
        return;
      }
    } else if (envelope.protocolVersion >= SyncEnvelope.currentProtocolVersion) {
      _appendLog('Отклонено v${envelope.protocolVersion} событие без защищённых sync-полей');
      return;
    }
    final decryptedEnvelope = SyncEnvelope(
      type: envelope.type,
      accountId: envelope.accountId,
      deviceId: envelope.deviceId,
      createdAt: envelope.createdAt,
      payload: decryptedPayload,
      protocolVersion: envelope.protocolVersion,
      operationId: envelope.operationId,
    );

    if (!_acceptTrustedDevicePayload(local, decryptedEnvelope)) {
      return;
    }

    switch (decryptedEnvelope.type) {
      case 'library_snapshot_requested':
        await _handleLibrarySnapshotRequested(decryptedEnvelope, local);
        break;
      case 'library_snapshot':
        await _handleLibrarySnapshot(decryptedEnvelope, local);
        break;
      case 'book_file_requested':
        await _handleBookFileRequested(decryptedEnvelope, local);
        break;
      case 'book_file_offer':
        await _handleBookFileOffer(decryptedEnvelope, local);
        break;
      case 'book_file_accept':
        unawaited(_handleBookFileAccept(decryptedEnvelope, local));
        break;
      case 'book_file_chunk':
        await _handleBookFileChunk(decryptedEnvelope, local);
        break;
      case 'book_file_chunk_ack':
        await _handleBookFileChunkAck(decryptedEnvelope, local);
        break;
      case 'book_file_error':
        await _handleBookFileError(decryptedEnvelope, local);
        break;
      case 'book_file_cancelled':
        await _handleBookFileCancelled(decryptedEnvelope, local);
        break;
      default:
        _appendLog('Неизвестное событие: ${decryptedEnvelope.type}');
    }
  }

  bool _acceptSecureEnvelope(SyncEnvelope envelope) {
    final eventId = ReadArcE2eCrypto.encryptedEventId(envelope.payload);
    if (eventId == null || eventId.isEmpty) {
      // Legacy encrypted payload from older test builds. Accept during rollout.
      return true;
    }
    final now = DateTime.now().toUtc();
    // issuedAt is authenticated and useful for diagnostics, but is deliberately
    // not an ordering or acceptance boundary: device clocks can be far apart.
    // Replay safety comes from eventId plus durable operationId idempotency.
    _seenSecureEventIds.removeWhere((_, seenAt) => seenAt.isBefore(now.subtract(_replayWindow)));
    final replayKey = '${envelope.accountId}:${envelope.deviceId}:$eventId';
    if (_seenSecureEventIds.containsKey(replayKey)) {
      _appendLog('Отклонён повтор события: ${envelope.type}');
      return false;
    }
    _seenSecureEventIds[replayKey] = now;
    return true;
  }

  bool _isRevokedDevice(LibraryManifest local, String deviceId) {
    for (final device in local.trustedDevices) {
      if (device.deviceId == deviceId) return device.isRevoked;
    }
    return false;
  }

  bool _acceptTrustedDevicePayload(LibraryManifest local, SyncEnvelope envelope) {
    final capability = envelope.type.startsWith('book_file_') ? SyncCapability.fileTransfer : SyncCapability.metadata;
    if (_authorization.allows(local, envelope.deviceId, capability)) return true;

    // First event from a freshly paired device can be its library snapshot. It is
    // already encrypted with the account key from the one-time QR invite. Accept
    // only if the snapshot explicitly introduces the sender as a trusted device
    // with a public key; all other unknown-device events are rejected.
    if (envelope.type == 'library_snapshot') {
      final payloadManifest = envelope.payload['manifest'];
      if (payloadManifest is Map) {
        final devices = (payloadManifest['trustedDevices'] as List?) ?? const [];
        for (final item in devices.whereType<Map>()) {
          final candidate = TrustedDeviceRecord.fromJson(Map<String, dynamic>.from(item));
          if (candidate.deviceId == envelope.deviceId && !candidate.isRevoked && candidate.hasPublicKey) {
            _appendLog('Принято первое доверенное событие от ${candidate.name}');
            return true;
          }
        }
      }
    }

    _appendLog('Отклонено событие от недоверенного устройства: ${envelope.deviceId}');
    return false;
  }

  Future<void> _handlePairingClaimed(SyncEnvelope envelope, LibraryManifest local) async {
    if (envelope.deviceId != 'relay') return;
    final ownerDeviceId = envelope.payload['ownerDeviceId']?.toString() ?? '';
    if (ownerDeviceId.isNotEmpty && ownerDeviceId != local.deviceId) return;

    final acceptedDeviceId = envelope.payload['acceptedDeviceId']?.toString().trim() ?? '';
    if (acceptedDeviceId.isEmpty || acceptedDeviceId == local.deviceId) return;

    final acceptedDeviceName = envelope.payload['acceptedDeviceName']?.toString().trim() ?? 'Устройство';
    final acceptedDevicePublicKey = envelope.payload['acceptedDevicePublicKey']?.toString().trim() ?? '';

    final updated = await _storage.trustDevice(
      deviceId: acceptedDeviceId,
      name: acceptedDeviceName.isEmpty ? 'Устройство' : acceptedDeviceName,
      role: 'device',
      publicKey: acceptedDevicePublicKey,
    );
    _emitManifest(updated);
    _appendLog('Устройство снова доверено через QR: $acceptedDeviceName');
    await broadcastLibrarySnapshot(reason: 'pairing_claimed_reauthorized_device');
  }

  Future<void> _handleLibrarySnapshotRequested(SyncEnvelope envelope, LibraryManifest local) async {
    final requester = envelope.payload['requestingDeviceId'] as String?;
    if (requester == local.deviceId) return;
    _appendLog('Получен запрос snapshot от ${envelope.deviceId}');
    await broadcastLibrarySnapshot(reason: 'requested_by_peer');
  }

  Future<void> _handleLibrarySnapshot(SyncEnvelope envelope, LibraryManifest local) async {
    final payloadManifest = envelope.payload['manifest'];
    if (payloadManifest is! Map) {
      _appendLog('Некорректный snapshot');
      return;
    }

    final remote = LibraryManifest.fromJson(Map<String, dynamic>.from(payloadManifest));
    if (remote.deviceId != envelope.deviceId) {
      _appendLog('Отклонён snapshot с несовпадающим deviceId');
      return;
    }
    if (remote.deviceId == local.deviceId) {
      // Ignore echoes of our own snapshot. Relay offline queues can deliver a
      // local snapshot back after reconnect; applying it is useless and can mask
      // more recent local changes.
      return;
    }
    final applied = await _metadataSyncEngine.applySnapshot(
      remote: remote,
      operationId: envelope.operationId,
      protocolVersion: envelope.protocolVersion,
    );
    if (applied.status == SnapshotApplyStatus.duplicate) {
      _appendLog('Повтор операции ${envelope.operationId} уже применён');
      return;
    }
    final saved = applied.manifest;
    if (saved.trustedDevices.any((device) => device.isRevoked)) {
      _directTransferServer.revokeAllShares();
    }
    _emitManifest(saved);
    if (saved.isCurrentDeviceRevoked) {
      _appendLog('Доступ этого устройства отозван. Синхронизация остановлена.');
      await disconnect(manual: true);
      _setState(state.value.copyWith(connected: false, statusText: 'Доступ этого устройства отозван'));
      return;
    }
    if (_tombstoneAcknowledgementsChanged(local, saved)) {
      unawaited(broadcastLibrarySnapshot(reason: 'tombstone_ack'));
    }
    _appendLog('Принят snapshot от ${remote.deviceName} — книг: ${remote.books.length}');
    _setState(state.value.copyWith(receivedEvents: state.value.receivedEvents + 1));
  }

  bool _tombstoneAcknowledgementsChanged(LibraryManifest before, LibraryManifest after) {
    final beforeBooks = {for (final book in before.books) book.id: book};
    for (final book in after.books) {
      final previous = beforeBooks[book.id];
      if (book.isDeleted &&
          (previous == null ||
              !setEquals(previous.tombstoneAckedByDeviceIds.toSet(), book.tombstoneAckedByDeviceIds.toSet()))) {
        return true;
      }
      final beforeBookmarks = {
        for (final bookmark in previous?.bookmarks ?? const <BookmarkRecord>[]) bookmark.id: bookmark,
      };
      for (final bookmark in book.bookmarks.where((item) => item.isDeleted)) {
        final previousBookmark = beforeBookmarks[bookmark.id];
        if (previousBookmark == null ||
            !setEquals(
              previousBookmark.tombstoneAckedByDeviceIds.toSet(),
              bookmark.tombstoneAckedByDeviceIds.toSet(),
            )) {
          return true;
        }
      }
    }
    return false;
  }

  Future<void> _handleBookFileRequested(SyncEnvelope envelope, LibraryManifest local) async {
    final payload = envelope.payload;
    final requestingDeviceId = payload['requestingDeviceId'] as String?;
    if (requestingDeviceId == null || requestingDeviceId == local.deviceId) return;

    final bookId = payload['bookId'] as String?;
    final transferId = payload['transferId'] as String?;
    if (bookId == null || transferId == null) return;

    final book = _findBook(local, bookId);
    if (book == null || !book.hasLocalSource) return;
    File file;
    try {
      file = await _storage.materializeBook(book);
    } catch (_) {
      _appendLog('Файл больше не доступен на этом устройстве: ${book.title}');
      try {
        final updated = await _storage.markLocalSourceUnavailable(book.id);
        _emitManifest(updated);
        await broadcastLibrarySnapshot(reason: 'file_missing_on_source');
      } catch (_) {
        // Best effort: transfer must still be terminated for the requester.
      }
      await _sendFileError(
        local,
        transferId,
        bookId,
        requestingDeviceId,
        'Файл больше недоступен на устройстве-источнике. Включите другое устройство с этой книгой или добавьте файл заново.',
      );
      return;
    }

    final chunkSize = math.min((payload['preferredChunkSize'] as num?)?.toInt() ?? _fileChunkSize, _fileChunkSize);
    final directUrls = await _createDirectShareUrls(book: book, file: file);

    if (directUrls.isEmpty) {
      _appendLog('Direct/LAN endpoint недоступен для ${book.title}; будет использован relay fallback');
    } else {
      _appendLog('Direct/LAN URLs для ${book.title}: ${directUrls.length}');
    }

    await _sendEnvelope(
      SyncEnvelope(
        type: 'book_file_offer',
        accountId: local.accountId,
        deviceId: local.deviceId,
        payload: {
          'transferId': transferId,
          'bookId': bookId,
          'sourceDeviceId': local.deviceId,
          'requestingDeviceId': requestingDeviceId,
          'fileName': book.fileName,
          'format': book.format,
          'sizeBytes': await file.length(),
          'sha256': book.contentSha256,
          'chunkSize': chunkSize,
          'binaryTransfer': true,
          'directDownloadUrls': directUrls,
          'directTransfer': directUrls.isNotEmpty,
        },
      ),
    );
    _appendLog('Предложен файл: ${book.title} → $requestingDeviceId');
  }

  Future<void> _handleBookFileOffer(SyncEnvelope envelope, LibraryManifest local) async {
    final payload = envelope.payload;
    if (payload['requestingDeviceId'] != local.deviceId) return;
    final transferId = payload['transferId'] as String?;
    final sourceDeviceId = payload['sourceDeviceId'] as String?;
    if (transferId == null || sourceDeviceId == null) return;
    final session = _downloadsByTransferId[transferId];
    if (session == null || session.sourceDeviceId != null) return;

    final offeredSha = payload['sha256'] as String?;
    if (offeredSha != null && offeredSha != session.expectedSha256) {
      _appendLog('Отклонён offer: SHA-256 не совпадает');
      return;
    }

    final chunkSize = (payload['chunkSize'] as num?)?.toInt() ?? _fileChunkSize;
    final prepared = await _fileTransferManager.prepare(
      PendingFileTransfer(
        transferId: transferId,
        bookId: session.bookId,
        fileName: session.fileName,
        format: session.format,
        expectedSha256: session.expectedSha256,
        expectedBytes: session.expectedBytes,
        chunkSize: chunkSize,
      ),
    );
    final tempFile = prepared.partialFile;
    final resumeBytes = prepared.resumeBytes;

    session
      ..sourceDeviceId = sourceDeviceId
      ..tempFile = tempFile
      ..chunkSize = chunkSize
      ..receivedBytes = resumeBytes
      ..expectedChunkIndex = prepared.nextChunkIndex;

    final resumeText = resumeBytes > 0
        ? 'Продолжаем с ${_formatBytes(resumeBytes)}...'
        : 'Источник найден, начинаем скачивание...';
    _setDownloadSnapshot(
      state.value
          .downloadForBook(session.bookId)!
          .copyWith(
            statusText: resumeText,
            peerDeviceId: sourceDeviceId,
            transferredBytes: resumeBytes,
            progressPercent: session.expectedBytes <= 0 ? 0 : (resumeBytes / session.expectedBytes) * 100,
            active: true,
            clearError: true,
          ),
    );

    final directUrls = ((payload['directDownloadUrls'] as List?) ?? const [])
        .map((item) => item.toString())
        .where((url) => url.trim().isNotEmpty)
        .toList();
    if (directUrls.isNotEmpty) {
      final directOk = await _tryDirectDownload(session, directUrls);
      if (directOk) return;
      if (session.cancelled || !_downloadsByTransferId.containsKey(session.transferId)) return;
      // A failed Direct/LAN stream can end at an arbitrary byte. Re-align the
      // durable partial before switching transports so relay chunk 0/N never
      // gets appended after an unaligned Direct tail.
      final relayPrepared = await _fileTransferManager.prepare(
        PendingFileTransfer(
          transferId: transferId,
          bookId: session.bookId,
          fileName: session.fileName,
          format: session.format,
          expectedSha256: session.expectedSha256,
          expectedBytes: session.expectedBytes,
          chunkSize: session.chunkSize,
        ),
      );
      session
        ..tempFile = relayPrepared.partialFile
        ..receivedBytes = relayPrepared.resumeBytes
        ..expectedChunkIndex = relayPrepared.nextChunkIndex;
      final existing = state.value.downloadForBook(session.bookId);
      if (existing != null) {
        _setDownloadSnapshot(
          existing.copyWith(statusText: 'Direct/LAN недоступен, используем relay...', active: true, clearError: true),
        );
      }
    }

    await _sendEnvelope(
      SyncEnvelope(
        type: 'book_file_accept',
        accountId: local.accountId,
        deviceId: local.deviceId,
        payload: {
          'transferId': transferId,
          'bookId': session.bookId,
          'sourceDeviceId': sourceDeviceId,
          'requestingDeviceId': local.deviceId,
          'chunkSize': session.chunkSize,
          'startChunkIndex': session.expectedChunkIndex,
          'binaryTransfer': true,
        },
      ),
    );
    _resetDownloadWatchdog(session);
    _appendLog('Принят источник файла: $sourceDeviceId');
  }

  Future<void> _handleBookFileAccept(SyncEnvelope envelope, LibraryManifest local) async {
    final payload = envelope.payload;
    if (payload['sourceDeviceId'] != local.deviceId) return;
    final transferId = payload['transferId'] as String?;
    final bookId = payload['bookId'] as String?;
    final requestingDeviceId = payload['requestingDeviceId'] as String?;
    if (transferId == null || bookId == null || requestingDeviceId == null) return;
    if (!_uploadLocks.add(transferId)) return;

    try {
      await _sendFileChunks(
        local: local,
        transferId: transferId,
        bookId: bookId,
        requestingDeviceId: requestingDeviceId,
        chunkSize: (payload['chunkSize'] as num?)?.toInt() ?? _fileChunkSize,
        startChunkIndex: (payload['startChunkIndex'] as num?)?.toInt() ?? 0,
        binaryTransfer: payload['binaryTransfer'] == true,
      );
    } finally {
      _uploadLocks.remove(transferId);
    }
  }

  Future<void> _handleSourceFileUnavailable(
    LibraryManifest local,
    String transferId,
    String bookId,
    String requestingDeviceId,
    String message,
  ) async {
    try {
      final updated = await _storage.markLocalSourceUnavailable(bookId);
      _emitManifest(updated);
      await broadcastLibrarySnapshot(reason: 'file_unavailable_on_source');
    } catch (_) {
      // The transfer error is more important than local manifest cleanup here.
    }
    await _sendFileError(
      local,
      transferId,
      bookId,
      requestingDeviceId,
      '$message. Файл больше недоступен на устройстве-источнике.',
    );
  }

  Future<void> _sendFileChunks({
    required LibraryManifest local,
    required String transferId,
    required String bookId,
    required String requestingDeviceId,
    required int chunkSize,
    required int startChunkIndex,
    required bool binaryTransfer,
  }) async {
    final book = _findBook(await _storage.loadManifest(), bookId);
    if (book == null || !book.hasLocalSource) {
      await _sendFileError(local, transferId, bookId, requestingDeviceId, 'Файл не найден у источника');
      return;
    }
    File file;
    try {
      file = await _storage.materializeBook(book);
    } catch (_) {
      await _handleSourceFileUnavailable(local, transferId, bookId, requestingDeviceId, 'Локальный файл отсутствует');
      return;
    }

    int size;
    try {
      size = await file.length();
    } catch (_) {
      await _handleSourceFileUnavailable(
        local,
        transferId,
        bookId,
        requestingDeviceId,
        'Не удалось прочитать локальный файл',
      );
      return;
    }
    final safeChunkSize = chunkSize.clamp(256 * 1024, _fileChunkSize).toInt();
    final totalChunks = (size / safeChunkSize).ceil();
    final safeStartChunkIndex = startChunkIndex.clamp(0, totalChunks).toInt();
    final startOffset = (safeStartChunkIndex * safeChunkSize).clamp(0, size).toInt();
    final uploadKey = 'upload:$transferId';
    _cancelledTransfers.remove(transferId);

    _updateTransferByKey(
      uploadKey,
      FileTransferSnapshot(
        transferId: transferId,
        bookId: bookId,
        direction: 'upload',
        fileName: book.fileName,
        peerDeviceId: requestingDeviceId,
        statusText: startOffset > 0 ? 'Возобновляем отправку...' : 'Отправка файла...',
        active: true,
        transferredBytes: startOffset,
        progressPercent: size == 0 ? 100 : (startOffset / size) * 100,
        totalBytes: size,
      ),
    );

    RandomAccessFile raf;
    try {
      raf = await file.open(mode: FileMode.read);
      await raf.setPosition(startOffset);
    } catch (_) {
      await _handleSourceFileUnavailable(
        local,
        transferId,
        bookId,
        requestingDeviceId,
        'Не удалось открыть файл для отправки',
      );
      return;
    }
    var chunkIndex = safeStartChunkIndex;
    var sentBytes = startOffset;
    var failed = false;
    final transferStartedAt = DateTime.now();
    try {
      while (true) {
        if (_cancelledTransfers.contains(transferId)) {
          _appendLog('Отправка отменена получателем: ${book.title}');
          break;
        }
        await beforeSendingFileChunk?.call(
          FileTransferChunkCheckpoint(
            transferId: transferId,
            bookId: bookId,
            chunkIndex: chunkIndex,
            receivedBytes: sentBytes,
          ),
        );
        final latestManifest = await _storage.loadManifest();
        if (latestManifest.isCurrentDeviceRevoked ||
            !_authorization.allows(latestManifest, requestingDeviceId, SyncCapability.fileTransfer)) {
          failed = true;
          _appendLog('Отправка остановлена: доступ устройства $requestingDeviceId отозван');
          break;
        }
        if (!await file.exists()) {
          failed = true;
          await _handleSourceFileUnavailable(
            local,
            transferId,
            bookId,
            requestingDeviceId,
            'Файл был удалён во время передачи',
          );
          break;
        }
        final data = await raf.read(safeChunkSize);
        if (data.isEmpty) break;
        sentBytes += data.length;
        var acknowledged = false;
        for (var attempt = 1; attempt <= 3 && !acknowledged; attempt++) {
          final ackKey = _ackKey(transferId, chunkIndex);
          final ackCompleter = Completer<void>();
          _uploadAckWaiters[ackKey] = ackCompleter;
          final sent = binaryTransfer
              ? await _sendBinaryFileChunk(
                  local: local,
                  transferId: transferId,
                  bookId: bookId,
                  requestingDeviceId: requestingDeviceId,
                  chunkIndex: chunkIndex,
                  totalChunks: totalChunks,
                  offset: chunkIndex * safeChunkSize,
                  totalBytes: size,
                  sha256Text: book.contentSha256,
                  data: data,
                )
              : await _sendEnvelope(
                  SyncEnvelope(
                    type: 'book_file_chunk',
                    accountId: local.accountId,
                    deviceId: local.deviceId,
                    payload: {
                      'transferId': transferId,
                      'bookId': bookId,
                      'sourceDeviceId': local.deviceId,
                      'requestingDeviceId': requestingDeviceId,
                      'chunkIndex': chunkIndex,
                      'totalChunks': totalChunks,
                      'offset': chunkIndex * safeChunkSize,
                      'totalBytes': size,
                      'sha256': book.contentSha256,
                      'dataBase64': base64Encode(data),
                    },
                  ),
                );
          if (!sent) {
            _uploadAckWaiters.remove(ackKey);
            if (attempt == 3) {
              failed = true;
              await _sendFileError(
                local,
                transferId,
                bookId,
                requestingDeviceId,
                'Не удалось отправить chunk $chunkIndex',
              );
              break;
            }
            continue;
          }
          try {
            await ackCompleter.future.timeout(_fileChunkAckTimeout);
            acknowledged = true;
          } on TimeoutException {
            _uploadAckWaiters.remove(ackKey);
            if (attempt < 3) {
              _updateTransferByKey(
                uploadKey,
                state.value.fileTransfers[uploadKey]!.copyWith(statusText: 'Повтор chunk $chunkIndex ($attempt/3)...'),
              );
              await Future<void>.delayed(const Duration(milliseconds: 350));
            } else {
              failed = true;
              await _sendFileError(
                local,
                transferId,
                bookId,
                requestingDeviceId,
                'Получатель не подтвердил chunk $chunkIndex',
              );
            }
          }
        }
        if (!acknowledged) break;
        final progress = size == 0 ? 100.0 : (sentBytes / size) * 100;
        final elapsed = DateTime.now().difference(transferStartedAt).inMilliseconds.clamp(1, 1 << 31);
        final mbps = ((sentBytes - startOffset) / (1024 * 1024)) / (elapsed / 1000.0);
        _updateTransferByKey(
          uploadKey,
          state.value.fileTransfers[uploadKey]!.copyWith(
            progressPercent: progress.clamp(0, 100).toDouble(),
            transferredBytes: sentBytes,
            statusText: 'Отправка: ${progress.clamp(0, 100).toStringAsFixed(1)}% • ${mbps.toStringAsFixed(1)} MB/s',
          ),
        );
        chunkIndex += 1;
        if (chunkIndex % 4 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }
      final wasCancelled = _cancelledTransfers.remove(transferId);
      final existingTransfer = state.value.fileTransfers[uploadKey]!;
      _updateTransferByKey(
        uploadKey,
        existingTransfer.copyWith(
          progressPercent: (wasCancelled || failed) ? existingTransfer.progressPercent : 100,
          transferredBytes: (wasCancelled || failed) ? existingTransfer.transferredBytes : size,
          statusText: wasCancelled
              ? 'Отправка отменена'
              : failed
              ? 'Отправка прервана'
              : 'Файл отправлен',
          active: false,
        ),
      );
      if (!wasCancelled && !failed) {
        _appendLog('Файл отправлен: ${book.title}');
      }
    } catch (error) {
      _updateTransferByKey(
        uploadKey,
        state.value.fileTransfers[uploadKey]!.copyWith(statusText: 'Ошибка отправки', active: false, error: '$error'),
      );
      await _sendFileError(local, transferId, bookId, requestingDeviceId, 'Ошибка отправки: $error');
    } finally {
      await raf.close();
    }
  }

  Future<bool> _sendBinaryFileChunk({
    required LibraryManifest local,
    required String transferId,
    required String bookId,
    required String requestingDeviceId,
    required int chunkIndex,
    required int totalChunks,
    required int offset,
    required int totalBytes,
    required String sha256Text,
    required List<int> data,
  }) async {
    final client = _client;
    if (client == null || !state.value.connected) return false;
    try {
      final encrypted = await ReadArcE2eCrypto.encryptBinaryFrame(
        accountEncryptionKey: local.accountEncryptionKey,
        clearBytes: data,
        headerFields: {
          'frame': 'readarc-binary-v1',
          'protocolVersion': SyncEnvelope.currentProtocolVersion,
          'operationId': '$transferId:$chunkIndex',
          'type': 'book_file_binary_chunk',
          'accountId': local.accountId,
          'deviceId': local.deviceId,
          'transferId': transferId,
          'bookId': bookId,
          'sourceDeviceId': local.deviceId,
          'requestingDeviceId': requestingDeviceId,
          'chunkIndex': chunkIndex,
          'totalChunks': totalChunks,
          'offset': offset,
          'totalBytes': totalBytes,
          'sha256': sha256Text,
        },
      );
      client.sendBinary(RelayBinaryMessage(header: encrypted.header, body: encrypted.cipherBytes));
      _setState(state.value.copyWith(sentEvents: state.value.sentEvents + 1));
      return true;
    } catch (error) {
      _appendLog('Не удалось отправить binary chunk $chunkIndex: $error');
      unawaited(_handleRelayDisconnected(error));
      return false;
    }
  }

  Future<void> _handleIncomingBinaryFrame(RelayBinaryMessage message) async {
    try {
      final local = await _storage.loadManifest();
      final header = message.header;
      if (header['type'] != 'book_file_binary_chunk') return;
      final protocolVersion = (header['protocolVersion'] as num?)?.toInt() ?? SyncEnvelope.minimumProtocolVersion;
      _metadataSyncEngine.validateProtocol(protocolVersion);
      if (header['accountId'] != local.accountId) return;
      if (header['requestingDeviceId'] != local.deviceId) return;
      final sourceDeviceId = header['sourceDeviceId']?.toString() ?? header['deviceId']?.toString() ?? '';
      if (!_authorization.allows(local, sourceDeviceId, SyncCapability.fileTransfer)) {
        _appendLog('Отклонён binary chunk от недоверенного/отозванного устройства: $sourceDeviceId');
        return;
      }
      final clearBytes = await ReadArcE2eCrypto.decryptBinaryFrame(
        header: header,
        cipherBytes: message.body,
        accountEncryptionKey: local.accountEncryptionKey,
      );
      await _handleBookFileBinaryChunk(header, clearBytes, local);
    } catch (error, stackTrace) {
      debugPrint('Binary sync event handling failed: $error\n$stackTrace');
      _appendLog('Ошибка binary transfer: $error');
    }
  }

  Future<void> _handleBookFileBinaryChunk(Map<String, dynamic> payload, List<int> data, LibraryManifest local) async {
    final transferId = payload['transferId'] as String?;
    if (transferId == null) return;
    final session = _downloadsByTransferId[transferId];
    if (session == null) return;
    if (session.sourceDeviceId != null && payload['sourceDeviceId'] != session.sourceDeviceId) return;

    final chunkIndex = (payload['chunkIndex'] as num?)?.toInt();
    if (chunkIndex == null) return;
    final tempFile = session.tempFile;
    if (tempFile == null) return;
    try {
      final result = await _fileTransferManager.commitChunk(
        partialFile: tempFile,
        expectedChunkIndex: session.expectedChunkIndex,
        receivedChunkIndex: chunkIndex,
        chunkSize: session.chunkSize,
        expectedBytes: (payload['totalBytes'] as num?)?.toInt() ?? session.expectedBytes,
        data: data,
      );
      if (result.disposition == IncomingChunkDisposition.duplicate) {
        await _sendChunkAck(local, session, chunkIndex);
        return;
      }
      if (result.disposition == IncomingChunkDisposition.waitingForMissingChunk) {
        _appendLog('Пропущен преждевременный binary chunk $chunkIndex; ожидаем ${session.expectedChunkIndex}');
        _resetDownloadWatchdog(session);
        return;
      }
      session
        ..expectedChunkIndex = result.nextChunkIndex
        ..receivedBytes = result.receivedBytes
        ..totalChunks = (payload['totalChunks'] as num?)?.toInt()
        ..expectedBytes = (payload['totalBytes'] as num?)?.toInt() ?? session.expectedBytes;

      final totalBytes = session.expectedBytes;
      final progress = totalBytes <= 0 ? 0.0 : (session.receivedBytes / totalBytes) * 100;
      final elapsed = DateTime.now().difference(session.startedAt).inMilliseconds.clamp(1, 1 << 31);
      final mbps = (session.receivedBytes / (1024 * 1024)) / (elapsed / 1000.0);
      _setDownloadSnapshot(
        state.value
            .downloadForBook(session.bookId)!
            .copyWith(
              statusText: 'Скачивание: ${progress.clamp(0, 100).toStringAsFixed(1)}% • ${mbps.toStringAsFixed(1)} MB/s',
              progressPercent: progress.clamp(0, 100).toDouble(),
              transferredBytes: session.receivedBytes,
              totalBytes: totalBytes,
              active: true,
            ),
      );

      _resetDownloadWatchdog(session);
      if (_pauseForInjectedFault(session, chunkIndex)) return;
      await _sendChunkAck(local, session, chunkIndex);

      final totalChunks = session.totalChunks;
      if (totalChunks != null && session.expectedChunkIndex >= totalChunks) {
        session.watchdog?.cancel();
        await _finalizeDownload(session);
      }
    } catch (error) {
      await _failDownload(session, 'Ошибка получения binary chunk: $error');
    }
  }

  Future<void> _sendChunkAck(LibraryManifest local, _DownloadSession session, int chunkIndex) async {
    await _sendEnvelope(
      SyncEnvelope(
        type: 'book_file_chunk_ack',
        accountId: local.accountId,
        deviceId: local.deviceId,
        payload: {
          'transferId': session.transferId,
          'bookId': session.bookId,
          'sourceDeviceId': session.sourceDeviceId,
          'requestingDeviceId': local.deviceId,
          'chunkIndex': chunkIndex,
          'receivedBytes': session.receivedBytes,
        },
      ),
    );
  }

  Future<void> _handleBookFileChunk(SyncEnvelope envelope, LibraryManifest local) async {
    final payload = envelope.payload;
    if (payload['requestingDeviceId'] != local.deviceId) return;
    final transferId = payload['transferId'] as String?;
    if (transferId == null) return;
    final session = _downloadsByTransferId[transferId];
    if (session == null) return;
    if (session.sourceDeviceId != null && payload['sourceDeviceId'] != session.sourceDeviceId) {
      return;
    }

    final chunkIndex = (payload['chunkIndex'] as num?)?.toInt();
    if (chunkIndex == null) return;
    final tempFile = session.tempFile;
    final dataBase64 = payload['dataBase64'] as String?;
    if (tempFile == null || dataBase64 == null) return;

    try {
      final data = base64Decode(dataBase64);
      final result = await _fileTransferManager.commitChunk(
        partialFile: tempFile,
        expectedChunkIndex: session.expectedChunkIndex,
        receivedChunkIndex: chunkIndex,
        chunkSize: session.chunkSize,
        expectedBytes: (payload['totalBytes'] as num?)?.toInt() ?? session.expectedBytes,
        data: data,
      );
      if (result.disposition == IncomingChunkDisposition.duplicate) {
        await _sendChunkAck(local, session, chunkIndex);
        return;
      }
      if (result.disposition == IncomingChunkDisposition.waitingForMissingChunk) {
        _appendLog('Пропущен преждевременный chunk $chunkIndex; ожидаем ${session.expectedChunkIndex}');
        _resetDownloadWatchdog(session);
        return;
      }
      session
        ..expectedChunkIndex = result.nextChunkIndex
        ..receivedBytes = result.receivedBytes
        ..totalChunks = (payload['totalChunks'] as num?)?.toInt()
        ..expectedBytes = (payload['totalBytes'] as num?)?.toInt() ?? session.expectedBytes;

      final totalBytes = session.expectedBytes;
      final progress = totalBytes <= 0 ? 0.0 : (session.receivedBytes / totalBytes) * 100;
      final elapsed = DateTime.now().difference(session.startedAt).inMilliseconds.clamp(1, 1 << 31);
      final mbps = (session.receivedBytes / (1024 * 1024)) / (elapsed / 1000.0);
      _setDownloadSnapshot(
        state.value
            .downloadForBook(session.bookId)!
            .copyWith(
              statusText: 'Скачивание: ${progress.clamp(0, 100).toStringAsFixed(1)}% • ${mbps.toStringAsFixed(1)} MB/s',
              progressPercent: progress.clamp(0, 100).toDouble(),
              transferredBytes: session.receivedBytes,
              totalBytes: totalBytes,
              active: true,
            ),
      );

      _resetDownloadWatchdog(session);
      if (_pauseForInjectedFault(session, chunkIndex)) return;
      await _sendChunkAck(local, session, chunkIndex);

      final totalChunks = session.totalChunks;
      if (totalChunks != null && session.expectedChunkIndex >= totalChunks) {
        session.watchdog?.cancel();
        await _finalizeDownload(session);
      }
    } catch (error) {
      await _failDownload(session, 'Ошибка получения chunk: $error');
    }
  }

  Future<void> _finalizeDownload(_DownloadSession session) async {
    final tempFile = session.tempFile;
    if (tempFile == null || !await tempFile.exists()) {
      await _failDownload(session, 'Временный файл не найден');
      return;
    }

    _setDownloadSnapshot(
      state.value.downloadForBook(session.bookId)!.copyWith(statusText: 'Проверяем SHA-256...', active: true),
    );

    if (!await _fileTransferManager.verifySha256(tempFile, session.expectedSha256)) {
      await _failDownload(session, 'SHA-256 полученного файла не совпадает с metadata', deletePartial: true);
      return;
    }

    final current = _findBook(await _storage.loadManifest(), session.bookId);
    if (current == null) {
      await _failDownload(session, 'Metadata книги исчезли до завершения передачи');
      return;
    }
    final manifest = await _storage.commitReceivedBook(book: current, verifiedFile: tempFile);
    await _fileTransferManager.markCompleted(session.bookId);
    _emitManifest(manifest);
    _downloadsByTransferId.remove(session.transferId);

    _clearTransferForBook(session.bookId);
    _appendLog('Файл скачан: ${session.fileName}');
    await broadcastLibrarySnapshot(reason: 'book_file_downloaded');
  }

  Future<void> _handleBookFileChunkAck(SyncEnvelope envelope, LibraryManifest local) async {
    final payload = envelope.payload;
    if (payload['sourceDeviceId'] != local.deviceId) return;
    final transferId = payload['transferId'] as String?;
    final chunkIndex = (payload['chunkIndex'] as num?)?.toInt();
    if (transferId == null || chunkIndex == null) return;
    final completer = _uploadAckWaiters.remove(_ackKey(transferId, chunkIndex));
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  String _ackKey(String transferId, int chunkIndex) => '$transferId:$chunkIndex';

  bool _pauseForInjectedFault(_DownloadSession session, int chunkIndex) {
    final injector = pauseAfterCommittedChunk;
    if (injector == null ||
        !injector(
          FileTransferChunkCheckpoint(
            transferId: session.transferId,
            bookId: session.bookId,
            chunkIndex: chunkIndex,
            receivedBytes: session.receivedBytes,
          ),
        )) {
      return false;
    }
    _appendLog('Fault injection: соединение оборвано после durable chunk $chunkIndex');
    _pauseActiveDownloads(statusText: 'Соединение оборвано после сохранения chunk. Ожидается restart/resume.');
    unawaited(disconnect(manual: true));
    return true;
  }

  void _pauseActiveDownloads({required String statusText}) {
    if (_downloadsByTransferId.isEmpty) return;
    for (final session in _downloadsByTransferId.values.toList(growable: false)) {
      session
        ..cancelled = true
        ..watchdog?.cancel();
      final existing = state.value.downloadForBook(session.bookId);
      if (existing != null) {
        _setDownloadSnapshot(existing.copyWith(statusText: statusText, active: false));
      }
    }
    _downloadsByTransferId.clear();
  }

  void _resetDownloadWatchdog(_DownloadSession session) {
    session.watchdog?.cancel();
    session.watchdog = Timer(_downloadIdleTimeout, () {
      final current = _downloadsByTransferId[session.transferId];
      if (current == null || current.sourceDeviceId == null) return;
      unawaited(_failDownload(current, 'Источник перестал отвечать во время скачивания'));
    });
  }

  Future<void> _handleBookFileError(SyncEnvelope envelope, LibraryManifest local) async {
    final payload = envelope.payload;
    if (payload['requestingDeviceId'] != local.deviceId) return;
    final transferId = payload['transferId'] as String?;
    if (transferId == null) return;
    final session = _downloadsByTransferId[transferId];
    if (session == null) return;
    await _failDownload(session, payload['message'] as String? ?? 'Ошибка передачи файла');
  }

  Future<void> _failDownload(_DownloadSession session, String message, {bool deletePartial = false}) async {
    session.watchdog?.cancel();
    if (deletePartial) {
      await _fileTransferManager.discard(session.bookId);
    }
    _downloadsByTransferId.remove(session.transferId);
    final existing = state.value.downloadForBook(session.bookId);
    if (existing != null) {
      _setDownloadSnapshot(
        existing.copyWith(
          statusText: deletePartial
              ? 'Ошибка скачивания'
              : 'Пауза/ошибка. Нажмите скачать ещё раз — продолжим, если возможно.',
          active: false,
          error: message,
        ),
      );
    }
    _appendLog('Ошибка скачивания ${session.fileName}: $message');
  }

  Future<void> _handleBookFileCancelled(SyncEnvelope envelope, LibraryManifest local) async {
    final payload = envelope.payload;
    if (payload['sourceDeviceId'] != local.deviceId) return;
    final transferId = payload['transferId'] as String?;
    if (transferId == null) return;
    _cancelledTransfers.add(transferId);
    final uploadKey = 'upload:$transferId';
    final existing = state.value.fileTransfers[uploadKey];
    if (existing != null) {
      _updateTransferByKey(uploadKey, existing.copyWith(statusText: 'Получатель отменил скачивание', active: false));
    }
  }

  Future<void> _resumePendingTransfers() async {
    if (!state.value.connected) return;
    final manifest = await _storage.loadManifest();
    final activeBooks = _downloadsByTransferId.values.map((session) => session.bookId).toSet();
    for (final pending in await _fileTransferManager.loadPending()) {
      if (activeBooks.contains(pending.bookId)) continue;
      final matches = manifest.books.where(
        (book) => book.id == pending.bookId && !book.isDeleted && !book.isDownloaded,
      );
      if (matches.isEmpty) {
        await _fileTransferManager.discard(pending.bookId);
        continue;
      }
      _appendLog('Возобновляем незавершённую передачу: ${pending.fileName}');
      await requestBookFile(matches.first);
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _ensureDirectFileServer() async {
    await _directTransferServer.ensureStarted();
  }

  Future<List<String>> _createDirectShareUrls({required BookRecord book, required File file}) =>
      _directTransferServer.createShareUrls(book: book, file: file);

  List<Uri> _directDownloadCandidates(List<String> urls) {
    final seen = <String>{};
    final candidates = <Uri>[];
    for (final rawUrl in urls) {
      final uri = Uri.tryParse(rawUrl.trim());
      if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) continue;
      if (!seen.add(uri.toString())) continue;
      candidates.add(uri);
    }
    candidates.sort((a, b) => _directHostRank(a.host).compareTo(_directHostRank(b.host)));
    return candidates;
  }

  int _directHostRank(String host) {
    if (host.startsWith('192.168.') ||
        host.startsWith('10.') ||
        host.startsWith('172.16.') ||
        host.startsWith('172.17.') ||
        host.startsWith('172.18.') ||
        host.startsWith('172.19.') ||
        host.startsWith('172.2') ||
        host.startsWith('172.30.') ||
        host.startsWith('172.31.')) {
      return 0;
    }
    final parts = host.split('.').map(int.tryParse).toList();
    if (parts.length == 4 && parts[0] == 100 && parts[1] != null && parts[1]! >= 64 && parts[1]! <= 127) {
      return 1; // Tailscale/CGNAT range: still usually fast, but after ordinary LAN.
    }
    return 2;
  }

  Future<Uri?> _selectReachableDirectUrl(List<Uri> candidates, String bookId) async {
    if (candidates.isEmpty) return null;
    final snap = state.value.downloadForBook(bookId);
    if (snap != null) {
      _setDownloadSnapshot(
        snap.copyWith(
          statusText: 'Быстро проверяем Direct/LAN (${candidates.length})...',
          active: true,
          clearError: true,
        ),
      );
    }

    final probing = candidates.take(12).toList(growable: false);
    final completer = Completer<Uri?>();
    var pending = probing.length;
    for (final uri in probing) {
      unawaited(
        _probeDirectUrl(uri)
            .then((ok) {
              if (ok && !completer.isCompleted) completer.complete(uri);
            })
            .whenComplete(() {
              pending -= 1;
              if (pending <= 0 && !completer.isCompleted) completer.complete(null);
            }),
      );
    }
    return completer.future.timeout(const Duration(seconds: 4), onTimeout: () => null);
  }

  Future<bool> _probeDirectUrl(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(milliseconds: 900);
    try {
      final request = await client.openUrl('HEAD', uri).timeout(const Duration(milliseconds: 1200));
      final response = await request.close().timeout(const Duration(milliseconds: 1500));
      final ok = response.statusCode == HttpStatus.ok || response.statusCode == HttpStatus.partialContent;
      try {
        await response.drain().timeout(const Duration(milliseconds: 300), onTimeout: () => null);
      } catch (_) {}
      return ok;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> _tryDirectDownload(_DownloadSession session, List<String> urls) async {
    final tempFile = session.tempFile;
    if (tempFile == null) return false;
    session.watchdog?.cancel();
    final candidates = _directDownloadCandidates(urls);
    final selected = await _selectReachableDirectUrl(candidates, session.bookId);
    if (selected == null) {
      _resetDownloadWatchdog(session);
      return false;
    }

    final ordered = <Uri>[selected, ...candidates.where((candidate) => candidate != selected)];
    for (final uri in ordered.take(3)) {
      final ok = await _downloadFromDirectUri(session, uri, tempFile);
      if (ok) return true;
      if (!_downloadsByTransferId.containsKey(session.transferId)) return true;
    }
    _resetDownloadWatchdog(session);
    return false;
  }

  Future<bool> _downloadFromDirectUri(_DownloadSession session, Uri uri, File tempFile) async {
    final existing = state.value.downloadForBook(session.bookId);
    if (existing != null) {
      _setDownloadSnapshot(existing.copyWith(statusText: 'Direct/LAN: соединяемся...', active: true, clearError: true));
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    IOSink? sink;
    try {
      var resumeBytes = await tempFile.exists() ? await tempFile.length() : 0;
      if (resumeBytes > session.expectedBytes) {
        await tempFile.writeAsBytes(const [], flush: true);
        resumeBytes = 0;
      }
      final request = await client.getUrl(uri).timeout(const Duration(seconds: 3));
      if (resumeBytes > 0) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$resumeBytes-');
      final response = await request.close().timeout(const Duration(seconds: 5));
      if (response.statusCode == HttpStatus.notFound || response.statusCode == HttpStatus.gone) {
        await response.drain();
        await _failDownload(session, 'Файл больше недоступен на устройстве-источнике');
        return true;
      }
      if (response.statusCode != HttpStatus.ok && response.statusCode != HttpStatus.partialContent) {
        await response.drain();
        return false;
      }
      final advertisedSha256 = response.headers.value('X-ReadArc-Sha256');
      if (advertisedSha256 != null && advertisedSha256.toLowerCase() != session.expectedSha256.toLowerCase()) {
        await response.drain();
        return false;
      }
      if (response.statusCode == HttpStatus.partialContent && resumeBytes > 0) {
        final contentRange = response.headers.value(HttpHeaders.contentRangeHeader);
        final match = contentRange == null ? null : RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(contentRange);
        final rangeStart = match == null ? null : int.tryParse(match.group(1)!);
        final rangeTotal = match == null ? null : int.tryParse(match.group(3)!);
        if (rangeStart != resumeBytes || (rangeTotal != null && rangeTotal != session.expectedBytes)) {
          await response.drain();
          return false;
        }
      }
      if (response.statusCode == HttpStatus.ok && resumeBytes > 0) {
        await tempFile.writeAsBytes(const [], flush: true);
        resumeBytes = 0;
      }
      session.receivedBytes = resumeBytes;
      sink = tempFile.openWrite(mode: FileMode.append);
      final startedAt = DateTime.now();
      var lastUi = DateTime.fromMillisecondsSinceEpoch(0);
      await for (final chunk in response.timeout(_directStreamIdleTimeout)) {
        if (session.cancelled) return false;
        sink.add(chunk);
        session.receivedBytes += chunk.length;
        final now = DateTime.now();
        if (now.difference(lastUi).inMilliseconds > 250) {
          lastUi = now;
          final progress = session.expectedBytes <= 0 ? 0.0 : (session.receivedBytes / session.expectedBytes) * 100;
          final elapsed = now.difference(startedAt).inMilliseconds.clamp(1, 1 << 31);
          final mbps = ((session.receivedBytes - resumeBytes) / (1024 * 1024)) / (elapsed / 1000.0);
          final snap = state.value.downloadForBook(session.bookId);
          if (snap != null) {
            _setDownloadSnapshot(
              snap.copyWith(
                statusText:
                    'Direct/LAN: ${progress.clamp(0, 100).toStringAsFixed(1)}% • ${mbps.toStringAsFixed(1)} MB/s',
                progressPercent: progress.clamp(0, 100).toDouble(),
                transferredBytes: session.receivedBytes,
                totalBytes: session.expectedBytes,
                active: true,
              ),
            );
          }
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (session.expectedBytes <= 0 || session.receivedBytes >= session.expectedBytes) {
        final snap = state.value.downloadForBook(session.bookId);
        if (snap != null) {
          _setDownloadSnapshot(snap.copyWith(statusText: 'Проверяем SHA-256...', active: true));
        }
        await _finalizeDownload(session);
        return true;
      }
      return false;
    } catch (error) {
      debugPrint('Direct/LAN download failed from $uri: $error');
      return false;
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      client.close(force: true);
    }
  }

  Future<void> _sendFileError(
    LibraryManifest local,
    String transferId,
    String bookId,
    String requestingDeviceId,
    String message,
  ) async {
    await _sendEnvelope(
      SyncEnvelope(
        type: 'book_file_error',
        accountId: local.accountId,
        deviceId: local.deviceId,
        payload: {
          'transferId': transferId,
          'bookId': bookId,
          'sourceDeviceId': local.deviceId,
          'requestingDeviceId': requestingDeviceId,
          'message': message,
        },
      ),
    );
  }

  BookRecord? _findBook(LibraryManifest manifest, String bookId) {
    for (final book in manifest.books) {
      if (book.id == bookId && !book.isDeleted) return book;
    }
    return null;
  }

  Future<bool> _sendEnvelope(SyncEnvelope envelope, {String? logLabel}) async {
    final client = _client;
    if (client == null || !state.value.connected) {
      _appendLog('Не отправлено ${envelope.type}: нет подключения к relay');
      return false;
    }
    try {
      final local = await _storage.loadManifest();
      if (local.isCurrentDeviceRevoked) {
        _appendLog('Не отправлено ${envelope.type}: доступ этого устройства отозван');
        await disconnect(manual: true);
        _setState(state.value.copyWith(connected: false, statusText: 'Доступ этого устройства отозван'));
        return false;
      }
      final encryptedPayload = await ReadArcE2eCrypto.encryptPayload(
        payload: {
          ...envelope.payload,
          '_sync': {'protocolVersion': envelope.protocolVersion, 'operationId': envelope.operationId},
        },
        accountEncryptionKey: local.accountEncryptionKey,
        eventType: envelope.type,
        accountId: envelope.accountId,
        deviceId: envelope.deviceId,
        createdAt: envelope.createdAt,
      );
      client.send(
        SyncEnvelope(
          type: envelope.type,
          accountId: envelope.accountId,
          deviceId: envelope.deviceId,
          createdAt: envelope.createdAt,
          payload: encryptedPayload,
          protocolVersion: envelope.protocolVersion,
          operationId: envelope.operationId,
        ),
      );
      if (logLabel != null && logLabel.isNotEmpty) {
        _appendLog(logLabel);
      }
      _setState(state.value.copyWith(sentEvents: state.value.sentEvents + 1));
      return true;
    } catch (error) {
      _appendLog('Не удалось отправить ${envelope.type}: $error');
      unawaited(_handleRelayDisconnected(error));
      return false;
    }
  }

  void _setDownloadSnapshot(FileTransferSnapshot snapshot) {
    _updateTransferByKey(snapshot.bookId, snapshot);
  }

  void _updateTransferByKey(String key, FileTransferSnapshot snapshot) {
    final updated = Map<String, FileTransferSnapshot>.from(state.value.fileTransfers);
    updated[key] = snapshot;
    _setState(state.value.copyWith(fileTransfers: Map.unmodifiable(updated)));
  }

  void _clearTransferForBook(String bookId) {
    final updated = Map<String, FileTransferSnapshot>.from(state.value.fileTransfers);
    updated.remove(bookId);
    _setState(state.value.copyWith(fileTransfers: Map.unmodifiable(updated)));
  }

  void _appendLog(String line) {
    if (_disposed) return;
    final timestamp = DateTime.now().toLocal().toIso8601String().substring(11, 19);
    final updated = ['[$timestamp] $line', ...state.value.logLines];
    _setState(state.value.copyWith(logLines: updated.take(30).toList()));
  }

  void _setState(SyncStateSnapshot snapshot) {
    if (_disposed) return;
    state.value = snapshot;
  }

  void _emitManifest(LibraryManifest manifest) {
    if (_disposed || _manifestChanges.isClosed) return;
    _manifestChanges.add(manifest);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final session in _downloadsByTransferId.values) {
      session.watchdog?.cancel();
    }
    _downloadsByTransferId.clear();
    await disconnect(manual: true);
    _reconnectTimer?.cancel();
    await _directTransferServer.dispose();
    await _manifestChanges.close();
    state.dispose();
  }
}

class _DownloadSession {
  _DownloadSession({
    required this.transferId,
    required this.bookId,
    required this.fileName,
    required this.format,
    required this.expectedSha256,
    required this.expectedBytes,
  });

  final String transferId;
  final String bookId;
  final String fileName;
  final String format;
  final String expectedSha256;
  int expectedBytes;

  String? sourceDeviceId;
  File? tempFile;
  int chunkSize = _defaultChunkSize;
  int expectedChunkIndex = 0;
  int receivedBytes = 0;
  int? totalChunks;
  bool cancelled = false;
  Timer? watchdog;
  final DateTime startedAt = DateTime.now();
}
