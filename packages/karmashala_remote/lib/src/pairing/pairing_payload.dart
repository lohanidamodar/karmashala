/// What the QR code carries: everything a phone needs to find this host once
/// and derive the device key with it. Single-use, and stale after five
/// minutes — the secret never outlives the dialog that showed it.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../client/relay_candidates.dart';
import '../protocol.dart';
import '../transport/key_schedule.dart';

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
    Uint8List? typedSecret,
    List<Uri> relays = const [],
  }) : secret = Uint8List.fromList(secret),
       typedSecret = typedSecret == null
           ? null
           : Uint8List.fromList(typedSecret),
       relays = List.unmodifiable([
         for (final candidate in candidatesFrom(relay, relays)) candidate.url,
       ]) {
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
    List<Uri> relays = const [],
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
      relays: relays,
    );
  }

  /// A fresh payload rooted in a typed code: the payload's secret and its
  /// rendezvous are both HKDF-derived from the 20 typed bytes, so a phone with
  /// only the code reaches the pairing session the QR names explicitly.
  static Future<PairingPayload> generateWithCode({
    required Uri relay,
    required DeviceId hostId,
    required CapabilitySet capabilities,
    Random? random,
    List<Uri> relays = const [],
  }) async {
    final rng = random ?? Random.secure();
    final typed = Uint8List.fromList([
      for (var i = 0; i < kTypedCodeSecretBytes; i++) rng.nextInt(256),
    ]);
    final secret = await derivePairingSecret(typed);
    final rendezvous = await derivePairingRendezvous(secret.bytes);
    return PairingPayload(
      relay: relay,
      rendezvous: rendezvous,
      secret: Uint8List.fromList(secret.bytes),
      hostId: hostId,
      capabilities: capabilities,
      typedSecret: typed,
      relays: relays,
    );
  }

  /// The relay the shown tab chose — and the one an older companion, which
  /// reads this field alone, will dial.
  final Uri relay;

  /// Every relay the host is serving right now, [relay] first. Additive on the
  /// wire: an older companion ignores the key and pairs on [relay]. A relay is
  /// only a meeting place, so carrying several costs nothing in trust.
  final List<Uri> relays;

  /// The relay path both ends meet on for the pairing conversation only.
  /// Random and carried here — unlike a session rendezvous, nothing derives it.
  final RendezvousId rendezvous;

  final int version;
  final Uint8List secret;
  final DeviceId hostId;

  /// What the host will grant, shown to the user on both screens.
  final CapabilitySet capabilities;

  /// The typed code's 20 secret bytes when this payload was generated with
  /// one — shown on the desktop, never encoded into the QR. Null for decoded
  /// payloads and pre-typed-code generations.
  final Uint8List? typedSecret;

  /// The QR code's text.
  String encode() => jsonEncode({
    'relay': relay.toString(),
    'rendezvous': rendezvous.value,
    'v': version,
    'secret': base64Url.encode(secret),
    'hostId': hostId.value,
    'capabilities': capabilities.bits,
    // Only when there is something to add: a one-relay host's QR stays byte
    // for byte what it was before this loop.
    if (relays.length > 1)
      'relays': [for (final url in relays) url.toString()],
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
      // Absent (an older host, or a single-relay one) leaves the set as just
      // `relay`; a garbled entry costs its own relay and nothing else.
      relays: relayUrisFrom(json['relays']),
    );
  }
}
