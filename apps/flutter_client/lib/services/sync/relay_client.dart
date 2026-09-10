import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../models/manifest.dart';
import 'relay_lifecycle_guard.dart';

class RelayBinaryMessage {
  const RelayBinaryMessage({required this.header, required this.body});

  final Map<String, dynamic> header;
  final Uint8List body;

  Uint8List toFrame() {
    final headerBytes = utf8.encode(jsonEncode(header));
    final result = Uint8List(4 + headerBytes.length + body.length);
    final byteData = ByteData.view(result.buffer);
    byteData.setUint32(0, headerBytes.length, Endian.big);
    result.setRange(4, 4 + headerBytes.length, headerBytes);
    result.setRange(4 + headerBytes.length, result.length, body);
    return result;
  }

  static RelayBinaryMessage parse(List<int> raw) {
    final bytes = raw is Uint8List ? raw : Uint8List.fromList(raw);
    if (bytes.length < 4) throw StateError('Binary frame too short');
    final headerLength = ByteData.sublistView(bytes, 0, 4).getUint32(0, Endian.big);
    if (headerLength <= 0 || 4 + headerLength > bytes.length) {
      throw StateError('Invalid binary frame header length');
    }
    final headerRaw = utf8.decode(bytes.sublist(4, 4 + headerLength));
    final decoded = jsonDecode(headerRaw);
    if (decoded is! Map) throw StateError('Binary frame header is not an object');
    return RelayBinaryMessage(
      header: Map<String, dynamic>.from(decoded),
      body: Uint8List.fromList(bytes.sublist(4 + headerLength)),
    );
  }
}

class RelayClient {
  RelayClient({required this.relayUri, required this.accountId, required this.deviceId});

  final Uri relayUri;
  final String accountId;
  final String deviceId;

  WebSocketChannel? _channel;
  final _incoming = StreamController<SyncEnvelope>.broadcast();
  final _binaryIncoming = StreamController<RelayBinaryMessage>.broadcast();
  StreamSubscription<dynamic>? _subscription;

  Stream<SyncEnvelope> get incoming => _incoming.stream;
  Stream<RelayBinaryMessage> get binaryIncoming => _binaryIncoming.stream;

  Future<void> connect() async {
    final scheme = switch (relayUri.scheme) {
      'https' => 'wss',
      'wss' => 'wss',
      'ws' => 'ws',
      'http' => 'ws',
      _ => 'ws',
    };

    final basePath = relayUri.path.trim();
    final normalizedBase = basePath == '/' ? '' : basePath.replaceAll(RegExp(r'/+$'), '');
    final wsPath = normalizedBase.isEmpty || normalizedBase == '/ws'
        ? '/ws/$accountId/$deviceId'
        : '$normalizedBase/ws/$accountId/$deviceId';

    final wsUri = relayUri.replace(scheme: scheme, path: wsPath, query: '');
    final channel = WebSocketChannel.connect(wsUri);
    _channel = channel;
    // WebSocketChannel.connect() creates the channel synchronously. Waiting for
    // ready is important: otherwise the app may briefly mark sync as connected
    // even when the relay/tunnel is offline.
    await channel.ready.timeout(const Duration(seconds: 12));
    _subscription = channel.stream.listen(
      _handleRawMessage,
      onError: _incoming.addError,
      onDone: () {
        if (!_incoming.isClosed) {
          _incoming.addError(StateError('Relay connection closed'));
        }
      },
      cancelOnError: false,
    );
  }

  void _handleRawMessage(dynamic raw) {
    if (raw is List<int>) {
      try {
        _binaryIncoming.add(RelayBinaryMessage.parse(raw));
      } catch (error) {
        _incoming.add(_systemError('Cannot parse binary relay frame: $error'));
      }
      return;
    }
    if (raw is! String) return;
    try {
      final decodedRaw = jsonDecode(raw);
      if (decodedRaw is! Map) {
        _incoming.add(_systemError('Relay message is not an object'));
        return;
      }
      final decoded = Map<String, dynamic>.from(decodedRaw);
      final type = decoded['type'] as String?;
      if (type == 'peer_joined' ||
          type == 'peer_left' ||
          type == 'peer_list' ||
          type == 'pairing_claimed' ||
          type == 'error') {
        _incoming.add(
          SyncEnvelope(
            type: type ?? 'relay_system',
            accountId: decoded['accountId'] as String? ?? accountId,
            deviceId: decoded['deviceId'] as String? ?? 'relay',
            payload: decoded,
          ),
        );
        return;
      }
      if (type == null || decoded['payload'] is! Map) {
        _incoming.add(_systemError('Relay message has invalid sync envelope'));
        return;
      }
      _incoming.add(SyncEnvelope.fromJson(decoded));
    } catch (error) {
      _incoming.add(_systemError('Cannot parse relay message: $error'));
    }
  }

  SyncEnvelope _systemError(String message) =>
      SyncEnvelope(type: 'error', accountId: accountId, deviceId: 'relay-client', payload: {'message': message});

  void send(SyncEnvelope envelope) {
    sendControl(envelope.toJson());
  }

  void sendControl(Map<String, dynamic> payload) {
    final channel = _channel;
    if (channel == null) {
      throw StateError('RelayClient is not connected');
    }
    channel.sink.add(jsonEncode(payload));
  }

  void sendBinary(RelayBinaryMessage message) {
    final channel = _channel;
    if (channel == null) {
      throw StateError('RelayClient is not connected');
    }
    channel.sink.add(message.toFrame());
  }

  Future<void> close() async {
    final subscription = _subscription;
    _subscription = null;
    final channel = _channel;
    _channel = null;

    final cleanup = <Future<void>>[
      if (subscription != null) subscription.cancel(),
      if (channel != null) channel.sink.close(),
    ];
    if (cleanup.isEmpty) return;

    // After macOS wakes from sleep the old websocket can be half-open forever.
    // Cleanup is best effort: detach it immediately and never let it block the
    // next relay health probe/reconnect attempt.
    await waitForRelayCleanup(Future.wait(cleanup));
  }

  Future<void> dispose() async {
    await close();
    await _incoming.close();
    await _binaryIncoming.close();
  }
}
