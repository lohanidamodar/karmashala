import 'dart:typed_data';

import '../protocol.dart';
import 'companion_presence.dart';

/// The [PairedDevice.relayUrl] sentinel meaning "this machine's own LAN
/// relay" (the server's, since it moved out of the desktop app) — resolved to
/// the live local relay at serve time, because the LAN IP and port move while
/// the fact "my own relay" does not.
const String kLocalRelayMarker = 'local';

/// One phone paired with this desktop host — its identity, its long-lived key,
/// what it was granted at pairing, and the rendezvous generation counter the
/// key schedule rotates on: one counter per device, never two sequences.
class PairedDevice {
  PairedDevice({
    required this.id,
    required this.name,
    required Uint8List deviceKey,
    required this.capabilities,
    required this.generation,
    required this.createdAt,
    this.revoked = false,
    this.lastSeenAt,
    this.pushToken,
    this.pushPlatform,
    this.presence = CompanionPresence.unknown,
    this.relayUrl,
  }) : deviceKey = Uint8List.fromList(deviceKey);

  /// The companion's [DeviceId], lowercase hex.
  final String id;

  /// What the user calls this phone.
  final String name;

  /// The 32-byte device key from the pairing key schedule. **Empty once
  /// revoked** — revocation deletes the key, not just a flag.
  final Uint8List deviceKey;

  /// What this device was granted at pairing. Enforced per frame by the host.
  final CapabilitySet capabilities;

  /// The rendezvous generation counter (loop 64 key schedule). Both the
  /// rendezvous id and the direction keys are derived from it.
  final int generation;

  /// Revoked devices keep their row (so the list can say what happened) but
  /// have no key and are never listened for.
  final bool revoked;

  final DateTime createdAt;
  final DateTime? lastSeenAt;

  /// Push registration from `notifications.register`. Delivery is Loop D;
  /// this loop only persists what the phone sent.
  final String? pushToken;
  final String? pushPlatform;

  /// What the phone last said about itself on the same frame. **Read only to
  /// route a notification** (`PushFanout`), never to decide whether a frame is
  /// carried, so a reading left over from before a restart is harmless.
  final CompanionPresence presence;

  /// The relay this device was paired through, or [kLocalRelayMarker] for the
  /// machine's own LAN relay. Null only for a row missed by the v19 backfill.
  final String? relayUrl;

  /// Whether this device's frames travel through the machine's LAN relay.
  bool get pairedViaLocalRelay => relayUrl == kLocalRelayMarker;

  /// The hosted relay URL stored at pairing, or null for a local-relay
  /// device and for an unparsable/absent value.
  Uri? get hostedRelayUri {
    final url = relayUrl;
    if (url == null || url == kLocalRelayMarker) return null;
    final parsed = Uri.tryParse(url);
    return parsed != null && parsed.hasScheme ? parsed : null;
  }

  DeviceId get deviceId => DeviceId.parse(id);

  PairedDevice copyWith({
    String? name,
    Uint8List? deviceKey,
    CapabilitySet? capabilities,
    int? generation,
    bool? revoked,
    DateTime? lastSeenAt,
    String? pushToken,
    String? pushPlatform,
    CompanionPresence? presence,
    String? relayUrl,
  }) => PairedDevice(
    id: id,
    name: name ?? this.name,
    deviceKey: deviceKey ?? this.deviceKey,
    capabilities: capabilities ?? this.capabilities,
    generation: generation ?? this.generation,
    createdAt: createdAt,
    revoked: revoked ?? this.revoked,
    lastSeenAt: lastSeenAt ?? this.lastSeenAt,
    pushToken: pushToken ?? this.pushToken,
    pushPlatform: pushPlatform ?? this.pushPlatform,
    presence: presence ?? this.presence,
    relayUrl: relayUrl ?? this.relayUrl,
  );

  @override
  String toString() =>
      'PairedDevice($id, $name, g$generation${revoked ? ', revoked' : ''})';
}
