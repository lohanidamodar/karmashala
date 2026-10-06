import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// How far an `X-Karmashala-Timestamp` may be from the server's clock.
const Duration kWebhookTimestampWindow = Duration(minutes: 5);

/// How long a delivery id is remembered against a replay.
const Duration kWebhookReplayWindow = Duration(hours: 24);

/// Longest delivery id kept.
const int kWebhookDeliveryIdCap = 200;

/// What a call's signature headers say about it.
enum WebhookSignature {
  valid,

  /// Neither signature header was sent.
  missing,

  /// A signature was sent and does not match, or is malformed.
  invalid,

  /// The generic header's timestamp is outside [kWebhookTimestampWindow].
  stale,
}

const String _github = 'x-hub-signature-256';
const String _generic = 'x-karmashala-signature';
const String _timestamp = 'x-karmashala-timestamp';

/// Checks [body] against [secret]: GitHub's `X-Hub-Signature-256:
/// sha256=<hex>` over the raw body, or `X-Karmashala-Signature: sha256=<hex>`
/// over `<X-Karmashala-Timestamp>.<raw body>` inside the window. [headers]
/// are lowercase. An empty secret verifies nothing.
WebhookSignature verifyWebhookSignature({
  required String secret,
  required Map<String, String> headers,
  required List<int> body,
  required DateTime now,
}) {
  final github = headers[_github];
  final generic = headers[_generic];
  if (github == null && generic == null) return WebhookSignature.missing;
  if (secret.isEmpty) return WebhookSignature.invalid;
  final key = utf8.encode(secret);
  if (github != null) {
    final expected = Hmac(sha256, key).convert(body).bytes;
    return _matches(github, expected)
        ? WebhookSignature.valid
        : WebhookSignature.invalid;
  }
  final stamp = headers[_timestamp];
  final seconds = stamp == null ? null : int.tryParse(stamp.trim());
  if (seconds == null) return WebhookSignature.invalid;
  final signed = <int>[...utf8.encode('${stamp!.trim()}.'), ...body];
  final expected = Hmac(sha256, key).convert(signed).bytes;
  if (!_matches(generic!, expected)) return WebhookSignature.invalid;
  final at = DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
  return at.difference(now).abs() > kWebhookTimestampWindow
      ? WebhookSignature.stale
      : WebhookSignature.valid;
}

bool _matches(String header, List<int> expected) {
  final value = header.trim();
  if (!value.startsWith('sha256=')) return false;
  final given = _hexBytes(value.substring(7));
  return given != null && constantTimeEquals(given, expected);
}

List<int>? _hexBytes(String hex) {
  if (hex.length != 64) return null;
  final out = <int>[];
  for (var i = 0; i < hex.length; i += 2) {
    final byte = int.tryParse(hex.substring(i, i + 2), radix: 16);
    if (byte == null) return null;
    out.add(byte);
  }
  return out;
}

/// Compares every byte whatever the first difference, so the time a refusal
/// takes says nothing about how much of a signature was right.
bool constantTimeEquals(List<int> a, List<int> b) {
  var diff = a.length ^ b.length;
  final n = max(a.length, b.length);
  for (var i = 0; i < n; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    diff |= x ^ y;
  }
  return diff == 0;
}

/// GitHub's header value for [body] signed with [secret].
String webhookSignatureFor(String secret, List<int> body) =>
    'sha256=${Hmac(sha256, utf8.encode(secret)).convert(body)}';

/// The generic headers a caller sends: a timestamp and the signature over
/// `<timestamp>.<body>`.
Map<String, String> webhookGenericHeaders(
  String secret,
  List<int> body, {
  required DateTime at,
}) {
  final stamp = '${at.millisecondsSinceEpoch ~/ 1000}';
  final mac = Hmac(
    sha256,
    utf8.encode(secret),
  ).convert([...utf8.encode('$stamp.'), ...body]);
  return {_timestamp: stamp, _generic: 'sha256=$mac'};
}

/// The id a caller gave this delivery, from the first header that names one.
String? webhookDeliveryId(Map<String, String> headers) {
  for (final name in const [
    'x-github-delivery',
    'x-karmashala-delivery',
    'x-request-id',
  ]) {
    final value = headers[name]?.trim();
    if (value == null || value.isEmpty) continue;
    return value.length > kWebhookDeliveryIdCap
        ? value.substring(0, kWebhookDeliveryIdCap)
        : value;
  }
  return null;
}

/// What a call's log keeps of its body: SHA-256, hex. Never the body.
String webhookBodyHash(List<int> body) => sha256.convert(body).toString();

final Random _random = Random.secure();

String _hex(int bytes) => [
  for (var i = 0; i < bytes; i++)
    _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
].join();

/// A new hook id: 128 random bits, 32 lowercase hex.
String newWebhookHookId() => _hex(16);

/// A new signing secret: 256 random bits, base64url, with a recognisable
/// prefix so one pasted in the wrong place is easy to spot.
String newWebhookSecret() {
  final bytes = [for (var i = 0; i < 32; i++) _random.nextInt(256)];
  return 'whsec_${base64Url.encode(bytes).replaceAll('=', '')}';
}

/// A server's hooks listen key: 256 random bits, 64 lowercase hex.
String newWebhookListenKey() => _hex(32);
