import 'dart:typed_data';

import '../protocol.dart';
import 'paired_device.dart';

/// [device] as a client other than its server is told it: **no key, no
/// generation, no push token, no presence** — the secrets stay in the store.
Map<String, Object?> pairedDeviceToJson(PairedDevice device) => {
  'id': device.id,
  'name': device.name,
  'capabilities': device.capabilities.bits,
  'revoked': device.revoked,
  'createdAt': device.createdAt.toUtc().toIso8601String(),
  'lastSeenAt': ?device.lastSeenAt?.toUtc().toIso8601String(),
  'relayUrl': ?device.relayUrl,
  'relayMoveTo': ?device.relayMoveTo,
  'relayMovedFrom': ?device.relayMovedFrom,
  if (!device.relayMoveSettled) 'relayMoveSettled': false,
};

/// A device as [pairedDeviceToJson] told it. Throws [FormatException] for one
/// out of shape.
PairedDevice pairedDeviceFromJson(Map<String, Object?> json) {
  final id = json['id'];
  final name = json['name'];
  final capabilities = json['capabilities'];
  final createdAt = DateTime.tryParse('${json['createdAt']}');
  final lastSeen = json['lastSeenAt'];
  final relay = json['relayUrl'];
  final moveTo = json['relayMoveTo'];
  final movedFrom = json['relayMovedFrom'];
  if (id is! String ||
      name is! String ||
      capabilities is! int ||
      createdAt == null ||
      (lastSeen != null && lastSeen is! String) ||
      (relay != null && relay is! String) ||
      (moveTo != null && moveTo is! String) ||
      (movedFrom != null && movedFrom is! String)) {
    throw const FormatException('not a paired device');
  }
  return PairedDevice(
    id: id,
    name: name,
    deviceKey: Uint8List(0),
    capabilities: CapabilitySet(capabilities),
    generation: 0,
    revoked: json['revoked'] == true,
    createdAt: createdAt.toUtc(),
    lastSeenAt: lastSeen == null
        ? null
        : DateTime.parse(lastSeen as String).toUtc(),
    relayUrl: relay as String?,
    relayMoveTo: moveTo as String?,
    relayMovedFrom: movedFrom as String?,
    relayMoveSettled: json['relayMoveSettled'] != false,
  );
}

/// [device] with what [pairedDeviceToJson] leaves out cleared.
PairedDevice pairedDeviceWithoutSecrets(PairedDevice device) =>
    pairedDeviceFromJson(pairedDeviceToJson(device));

/// Whether two devices read the same to a client.
bool samePairedDevice(PairedDevice a, PairedDevice b) =>
    a.id == b.id &&
    a.name == b.name &&
    a.capabilities.bits == b.capabilities.bits &&
    a.revoked == b.revoked &&
    a.createdAt == b.createdAt &&
    a.lastSeenAt == b.lastSeenAt &&
    a.relayUrl == b.relayUrl &&
    a.relayMoveTo == b.relayMoveTo &&
    a.relayMovedFrom == b.relayMovedFrom &&
    a.relayMoveSettled == b.relayMoveSettled;

/// The paired-device list's order: newest first, then by id.
int comparePairedDevices(PairedDevice a, PairedDevice b) {
  final byAge = b.createdAt.compareTo(a.createdAt);
  return byAge != 0 ? byAge : a.id.compareTo(b.id);
}

/// A device's name as stored, or null when [name] is blank.
String? pairedDeviceNameOf(String name) {
  final trimmed = name.trim();
  return trimmed.isEmpty ? null : trimmed;
}
