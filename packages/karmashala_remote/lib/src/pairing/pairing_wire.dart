/// The little wire vocabulary underneath the session protocol: the cleartext
/// hellos that route a connection and name the phone, and the sealed pairing
/// messages that prove both ends hold the key. Cleartext here carries no
/// secrets; everything after the hellos is sealed.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../protocol.dart';

/// Longest cleartext hello the host will parse.
const int kMaxHelloBytes = 4096;

Map<String, Object?>? _decodeMap(List<int> frame) {
  if (frame.isEmpty || frame.length > kMaxHelloBytes) return null;
  try {
    final json = jsonDecode(utf8.decode(frame));
    return json is Map<String, Object?> ? json : null;
  } on FormatException {
    return null;
  }
}

/// A hello from a phone that knows `link.relay.move`: it saves a move the host
/// asks for, and acknowledges it, before it attaches.
const String kLinkFeatureRelayMove = 'relay.move';

/// The first frame a companion sends on any connection: which rendezvous — and
/// therefore which sealed channel — this link belongs to. Required on the LAN
/// path, where a TCP listener has no URL.
class LinkHello {
  const LinkHello(
    this.rendezvous, {
    this.resume = false,
    this.features = const {},
  });

  final RendezvousId rendezvous;

  /// This socket comes back for a suspended host link: its first sealed frame
  /// is a `link.resume` (Stage 0 step 16). A routing hint only — the sealed
  /// frame is the proof. Omitted when false, so a plain hello's bytes are
  /// exactly as before; a server that predates it reads a plain hello.
  final bool resume;

  /// What this end understands beyond the protocol's minimum, such as
  /// [kLinkFeatureRelayMove]. Cleartext, so a hint only: it decides whether a
  /// frame is offered, never whether one is trusted. Omitted when empty.
  final Set<String> features;

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'karmashala': 'link',
        'r': rendezvous.value,
        if (resume) 'resume': true,
        if (features.isNotEmpty) 'f': features.toList(),
      }),
    ),
  );

  static LinkHello? tryDecode(List<int> frame) {
    final json = _decodeMap(frame);
    if (json == null || json['karmashala'] != 'link') return null;
    final r = json['r'];
    if (r is! String || !RendezvousId.pattern.hasMatch(r)) return null;
    final f = json['f'];
    return LinkHello(
      RendezvousId.parse(r),
      resume: json['resume'] == true,
      features: f is List
          ? {
              for (final x in f)
                if (x is String) x,
            }
          : const {},
    );
  }
}

/// The companion naming itself on the pairing rendezvous. Cleartext by
/// necessity — the device key cannot exist until both ends know both ids —
/// and carrying nothing the sealed confirmation does not then prove.
class PairHello {
  const PairHello({
    required this.deviceId,
    required this.name,
    this.needsHostIdentity = false,
  });

  final DeviceId deviceId;
  final String name;

  /// True on the typed-code path: the phone holds only the secret and asks the
  /// host to deliver its identity in a confirm sealed by the secret alone.
  /// Omitted from the wire when false, so QR-path bytes stay exactly as before.
  final bool needsHostIdentity;

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'karmashala': 'pair',
        'device': deviceId.value,
        'name': name,
        'v': kProtocolVersion,
        if (needsHostIdentity) 'needHost': true,
      }),
    ),
  );

  static PairHello? tryDecode(List<int> frame) {
    final json = _decodeMap(frame);
    if (json == null || json['karmashala'] != 'pair') return null;
    final device = json['device'];
    final name = json['name'];
    if (device is! String || name is! String) return null;
    if (name.isEmpty || name.length > 64) return null;
    final DeviceId id;
    try {
      id = DeviceId.parse(device);
    } on ProtocolException {
      return null;
    }
    return PairHello(
      deviceId: id,
      name: name,
      needsHostIdentity: json['needHost'] == true,
    );
  }
}

/// The sealed pairing messages. Tiny JSON maps rather than protocol envelopes:
/// pairing happens *below* the session protocol, at generation 0.
class PairingMessage {
  const PairingMessage._();

  static const String confirm = 'pair.confirm';
  static const String ack = 'pair.ack';
  static const String done = 'pair.done';

  static Uint8List encodeConfirm({
    required String hostName,
    required CapabilitySet capabilities,
    DeviceId? hostId,
  }) => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        't': confirm,
        'host': hostName,
        'capabilities': capabilities.bits,
        // Only the typed-code path asks for it; the QR carried it already.
        if (hostId != null) 'hostId': hostId.value,
      }),
    ),
  );

  static Uint8List encodeAck() =>
      Uint8List.fromList(utf8.encode(jsonEncode({'t': ack})));

  static Uint8List encodeDone() =>
      Uint8List.fromList(utf8.encode(jsonEncode({'t': done})));

  /// The `t` of a sealed pairing message, or null when [plaintext] is not one.
  static String? typeOf(List<int> plaintext) {
    final json = _decodeMap(plaintext);
    final t = json?['t'];
    return t is String ? t : null;
  }

  static Map<String, Object?>? decode(List<int> plaintext) =>
      _decodeMap(plaintext);
}
