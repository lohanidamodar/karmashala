/// What the QR code carries: everything a phone needs to find this host once
/// and derive the device key with it. Single-use, and stale after five
/// minutes — the secret never outlives the dialog that showed it.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../protocol.dart';

/// Bytes of pairing secret behind the QR code.
const int kPairingSecretBytes = 32;

/// How long a shown QR code stays redeemable.
const Duration kPairingTtl = Duration(minutes: 5);

/// The generation the first real session runs at. The pairing confirmation
/// itself seals frames at generation 0, so the session channel starts one
/// later — a captured pairing frame can never replay into the session.
const int kFirstSessionGeneration = 1;

/// The `{relay, rendezvous, version, secret, hostId, capabilities}` payload
/// from the design, encoded as one JSON string inside the QR code.
class PairingPayload {
  PairingPayload({
    required this.relay,
    required this.rendezvous,
    required Uint8List secret,
    required this.hostId,
    required this.capabilities,
    this.version = kProtocolVersion,
  }) : secret = Uint8List.fromList(secret) {
    if (secret.length < kPairingSecretBytes) {
      throw ArgumentError.value(
        secret.length,
        'secret',
        'must be at least $kPairingSecretBytes bytes',
      );
    }
  }

  /// A fresh payload: 32 random bytes of secret and a random (not derived)
  /// pairing rendezvous, both from [Random.secure] unless a test injects.
  factory PairingPayload.generate({
    required Uri relay,
    required DeviceId hostId,
    required CapabilitySet capabilities,
    Random? random,
  }) {
    final rng = random ?? Random.secure();
    Uint8List bytes(int n) =>
        Uint8List.fromList([for (var i = 0; i < n; i++) rng.nextInt(256)]);
    return PairingPayload(
      relay: relay,
      rendezvous: RendezvousId(bytes(RendezvousId.lengthInBytes)),
      secret: bytes(kPairingSecretBytes),
      hostId: hostId,
      capabilities: capabilities,
    );
  }

  final Uri relay;

  /// The relay path both ends meet on for the pairing conversation only.
  /// Random and carried here — unlike a session rendezvous, nothing derives it.
  final RendezvousId rendezvous;

  final int version;
  final Uint8List secret;
  final DeviceId hostId;

  /// What the host will grant, shown to the user on both screens.
  final CapabilitySet capabilities;

  /// The QR code's text.
  String encode() => jsonEncode({
    'relay': relay.toString(),
    'rendezvous': rendezvous.value,
    'v': version,
    'secret': base64Url.encode(secret),
    'hostId': hostId.value,
    'capabilities': capabilities.bits,
  });

  /// Parses a scanned QR string. Throws [ProtocolException] on anything that
  /// is not a pairing payload.
  static PairingPayload decode(String text) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      throw const ProtocolException('pairing payload is not JSON');
    }
    if (json is! Map<String, Object?>) {
      throw const ProtocolException('pairing payload is not an object');
    }
    final relay = json['relay'];
    final rendezvous = json['rendezvous'];
    final version = json['v'];
    final secret = json['secret'];
    final hostId = json['hostId'];
    if (relay is! String ||
        rendezvous is! String ||
        version is! int ||
        secret is! String ||
        hostId is! String) {
      throw const ProtocolException('pairing payload is missing fields');
    }
    final Uint8List secretBytes;
    try {
      secretBytes = base64Url.decode(secret);
    } on FormatException {
      throw const ProtocolException('pairing secret is not base64url');
    }
    return PairingPayload(
      relay: Uri.parse(relay),
      rendezvous: RendezvousId.parse(rendezvous),
      version: version,
      secret: secretBytes,
      hostId: DeviceId.parse(hostId),
      capabilities: CapabilitySet.fromJson(json['capabilities'] ?? 0),
    );
  }
}
