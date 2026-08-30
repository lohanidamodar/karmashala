import 'dart:typed_data';

import '../protocol.dart';

/// One phone paired with this desktop host.
///
/// The row is the host's whole memory of the device: its identity, its
/// long-lived key, what it was granted at pairing, and the rendezvous
/// generation counter the key schedule rotates on (loop 64: one counter per
/// device, never two sequence numbers).
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
  );

  @override
  String toString() =>
      'PairedDevice($id, $name, g$generation${revoked ? ', revoked' : ''})';
}
