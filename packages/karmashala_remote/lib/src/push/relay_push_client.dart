/// The host's HTTP client for the relay's push endpoints: register a token
/// under the opaque push tag, and hand over a sealed payload. Both best-effort;
/// the relay never sees more than the tag, the token and ciphertext.
library;

import 'dart:convert';
import 'dart:io';

/// Posts one JSON body and answers status + body — the seam tests inject so
/// nothing here ever touches a real network.
typedef PushPost =
    Future<({int status, String body})> Function(Uri url, String jsonBody);

/// What one push request came to.
enum PushOutcome {
  /// The relay accepted it for delivery.
  accepted,

  /// The relay does not know the tag (it restarted); register and retry.
  unknownTag,

  /// The relay has no FCM configured; nothing to retry.
  notConfigured,

  /// The push service says the token is gone; re-registration must wait for
  /// the phone to send a fresh token.
  tokenGone,

  /// Anything else — network trouble, a 5xx, an unreadable answer.
  failed,
}

class RelayPushClient {
  RelayPushClient({required Uri relay, PushPost? post, this.onLog})
    : registerEndpoint = endpointFor(relay, 'v1/push/register'),
      pushEndpoint = endpointFor(relay, 'v1/push'),
      _post = post ?? _httpPost;

  final Uri registerEndpoint;
  final Uri pushEndpoint;
  final PushPost _post;

  /// Lifecycle only — never called with a tag, a token or a payload.
  final void Function(String message)? onLog;

  /// Maps the relay base URL (usually `wss://…`) onto an HTTP endpoint,
  /// keeping a self-hoster's port and path prefix.
  static Uri endpointFor(Uri relay, String path) {
    final scheme = switch (relay.scheme) {
      'https' || 'wss' => 'https',
      'http' || 'ws' => 'http',
      final other => throw ArgumentError('unusable relay scheme: $other'),
    };
    final base = relay.path.endsWith('/')
        ? relay.path.substring(0, relay.path.length - 1)
        : relay.path;
    return relay.replace(scheme: scheme, path: '$base/$path');
  }

  /// Registers [token] under [tag]. True when the relay stored it.
  Future<bool> register({
    required String tag,
    required String token,
    required String platform,
  }) async {
    final (:status, body: _) = await _post(
      registerEndpoint,
      jsonEncode({'tag': tag, 'token': token, 'platform': platform}),
    );
    if (status == 204) return true;
    onLog?.call('push registration refused: $status');
    return false;
  }

  /// Asks the relay to deliver [payloadB64] to whoever registered [tag].
  Future<PushOutcome> push({
    required String tag,
    required String payloadB64,
  }) async {
    final (:status, body: _) = await _post(
      pushEndpoint,
      jsonEncode({'tag': tag, 'payload': payloadB64}),
    );
    return switch (status) {
      202 => PushOutcome.accepted,
      404 => PushOutcome.unknownTag,
      410 => PushOutcome.tokenGone,
      503 => PushOutcome.notConfigured,
      _ => PushOutcome.failed,
    };
  }

  /// The production poster. Short timeout: push is best-effort and nothing
  /// may block behind it.
  static Future<({int status, String body})> _httpPost(
    Uri url,
    String jsonBody,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.postUrl(url);
      request.headers.contentType = ContentType.json;
      request.write(jsonBody);
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 15));
      return (status: response.statusCode, body: body);
    } finally {
      client.close(force: true);
    }
  }
}
