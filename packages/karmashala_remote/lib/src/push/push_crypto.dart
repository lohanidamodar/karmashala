/// Sealing for push payloads, shared by the host (seals) and the companion
/// (opens): every hop but the ends sees only ciphertext, and the relay
/// addresses the phone by a **push tag** derived from the device key — never a
/// device id, and never linkable to a rendezvous. No sequence numbers: a
/// replayed push collapses into the notification already shown.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../transport/key_schedule.dart';

/// HKDF info label for the push sealing key.
const String kPushKeyInfo = 'push-payload';

/// HKDF info label for the relay-facing push tag.
const String kPushTagInfo = 'push-tag';

/// AEAD associated data for every push box.
const String kPushAad = 'push';

/// Bytes in a push tag; rendered as 32 lowercase hex characters.
const int kPushTagBytes = 16;

/// The attention words a push payload's `kind` may carry — the same wire
/// vocabulary `session.changed` uses for its `attention` field.
const List<String> kPushAttentionKinds = [
  'finished',
  'needs_approval',
  'failed',
];

/// A push payload that would not open. Never quotes contents.
class PushPayloadException implements Exception {
  const PushPayloadException(this.message);

  final String message;

  @override
  String toString() => 'PushPayloadException: $message';
}

final Hkdf _hkdf32 = Hkdf(hmac: Hmac.sha256(), outputLength: kDeviceKeyBytes);
final Hkdf _hkdf16 = Hkdf(hmac: Hmac.sha256(), outputLength: kPushTagBytes);

/// The sealing key for push payloads under [deviceKey].
Future<SecretKeyData> derivePushKey(SecretKeyData deviceKey) async {
  final key = await _hkdf32.deriveKey(
    secretKey: SecretKey(deviceKey.bytes),
    nonce: kKeyScheduleSalt,
    info: kPushKeyInfo.codeUnits,
  );
  return SecretKeyData(key.bytes);
}

/// The opaque tag this pairing registers its push token under — 32 lowercase
/// hex characters the relay can hold without learning anything.
Future<String> derivePushTag(SecretKeyData deviceKey) async {
  final tag = await _hkdf16.deriveKey(
    secretKey: SecretKey(deviceKey.bytes),
    nonce: kKeyScheduleSalt,
    info: kPushTagInfo.codeUnits,
  );
  return [
    for (final byte in tag.bytes) byte.toRadixString(16).padLeft(2, '0'),
  ].join();
}

/// The JSON the host seals into a push: the attention news, worded with the
/// same `kind` vocabulary the session API uses.
Map<String, Object?> attentionPushPayload({
  required String sessionId,
  required String title,
  required String kind,
  required DateTime at,
  String? detail,
}) => {
  'v': 1,
  'sessionId': sessionId,
  'title': title,
  'kind': kind,
  'at': at.toUtc().toIso8601String(),
  // The desktop's own sentence, when the kind has one to say.
  'detail': ?detail,
};

/// Seals [payload] as `nonce(24) || ciphertext || mac(16)` under the push key.
Future<Uint8List> sealPushPayload({
  required SecretKeyData deviceKey,
  required Map<String, Object?> payload,
  List<int> Function()? nonceSource,
}) async {
  final cipher = Xchacha20.poly1305Aead();
  final box = await cipher.encrypt(
    utf8.encode(jsonEncode(payload)),
    secretKey: await derivePushKey(deviceKey),
    nonce: (nonceSource ?? _randomNonce)(),
    aad: kPushAad.codeUnits,
  );
  return Uint8List.fromList(box.concatenation());
}

/// Opens a sealed push payload, or throws [PushPayloadException].
Future<Map<String, Object?>> openPushPayload({
  required SecretKeyData deviceKey,
  required List<int> sealed,
}) async {
  if (sealed.length < 24 + 16) {
    throw const PushPayloadException('payload is shorter than its overhead');
  }
  final cipher = Xchacha20.poly1305Aead();
  final List<int> opened;
  try {
    opened = await cipher.decrypt(
      SecretBox.fromConcatenation(sealed, nonceLength: 24, macLength: 16),
      secretKey: await derivePushKey(deviceKey),
      aad: kPushAad.codeUnits,
    );
  } on SecretBoxAuthenticationError {
    throw const PushPayloadException('authentication failed');
  } on ArgumentError {
    throw const PushPayloadException('payload is malformed');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(opened));
  } on FormatException {
    throw const PushPayloadException('payload is not JSON');
  }
  if (decoded is! Map<String, Object?>) {
    throw const PushPayloadException('payload is not an object');
  }
  return decoded;
}

final Random _random = Random.secure();

List<int> _randomNonce() => [for (var i = 0; i < 24; i++) _random.nextInt(256)];
