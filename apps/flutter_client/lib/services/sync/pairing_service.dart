import 'dart:convert';
import 'dart:io';

import '../../models/sync_settings.dart';
import 'connection_manager.dart';

class PairingHttpException implements IOException {
  PairingHttpException({required this.statusCode, required this.message});

  final int statusCode;
  final String message;

  bool get isTransient => statusCode == 408 || statusCode == 429 || statusCode >= 500;

  @override
  String toString() => 'PairingHttpException($statusCode): $message';
}

/// Relay-side pairing transport. Account mutation remains in StorageService.
class PairingService {
  PairingService(this._connections);

  final ConnectionManager _connections;

  void validateEndpoint(SyncSettings settings) {
    if (settings.usesOfficialPlaceholder) {
      throw StateError('Официальный relay ReadArc не настроен в этой сборке.');
    }
  }

  Uri endpointUri(String relayUrl, String path) => _connections.endpointUri(relayUrl, path);

  Future<Map<String, dynamic>> postJson(Uri uri, Map<String, dynamic> body) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
      final response = await request.close().timeout(const Duration(seconds: 12));
      final responseBody = await response.transform(utf8.decoder).join();
      final decoded = responseBody.isEmpty ? <String, dynamic>{} : jsonDecode(responseBody);
      if (decoded is! Map) throw StateError('Relay вернул не JSON-объект');
      final result = Map<String, dynamic>.from(decoded);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw PairingHttpException(
          statusCode: response.statusCode,
          message: result['message']?.toString() ?? 'HTTP ${response.statusCode}',
        );
      }
      return result;
    } finally {
      client.close(force: true);
    }
  }
}
