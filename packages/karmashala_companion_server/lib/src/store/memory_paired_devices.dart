import 'dart:typed_data';

import 'package:karmashala_remote/remote.dart';

/// Paired devices kept in memory, with the store's rules: for a companion
/// server with no store (a test's host).
class MemoryPairedDeviceStore implements PairedDeviceStore {
  final _rows = <String, PairedDevice>{};

  @override
  List<PairedDevice> getAll() => [..._rows.values]..sort(comparePairedDevices);

  @override
  List<PairedDevice> getActive() => [
    for (final device in getAll())
      if (!device.revoked) device,
  ];

  @override
  PairedDevice? getById(String id) => _rows[id];

  @override
  void insert(PairedDevice device) {
    final before = _rows[device.id];
    _rows[device.id] = before == null
        ? device
        : PairedDevice(
            id: device.id,
            name: device.name,
            deviceKey: device.deviceKey,
            capabilities: device.capabilities,
            generation: device.generation,
            createdAt: before.createdAt,
            revoked: device.revoked,
            lastSeenAt: device.lastSeenAt ?? before.lastSeenAt,
            pushToken: device.pushToken ?? before.pushToken,
            pushPlatform: device.pushPlatform ?? before.pushPlatform,
            presence: before.presence,
            relayUrl: device.relayUrl,
          );
  }

  void _update(String id, PairedDevice Function(PairedDevice) change) {
    final device = _rows[id];
    if (device != null) _rows[id] = change(device);
  }

  @override
  void updateLastSeen(String id, DateTime at) =>
      _update(id, (d) => d.copyWith(lastSeenAt: at));

  @override
  void updateGeneration(String id, int generation) =>
      _update(id, (d) => d.copyWith(generation: generation));

  @override
  void rename(String id, String name) {
    final named = pairedDeviceNameOf(name);
    if (named != null) _update(id, (d) => d.copyWith(name: named));
  }

  @override
  void updateCapabilities(String id, CapabilitySet capabilities) => _update(
    id,
    (d) => d.revoked ? d : d.copyWith(capabilities: capabilities),
  );

  @override
  void revoke(String id) => _update(
    id,
    (d) => PairedDevice(
      id: d.id,
      name: d.name,
      deviceKey: Uint8List(0),
      capabilities: d.capabilities,
      generation: d.generation,
      createdAt: d.createdAt,
      revoked: true,
      lastSeenAt: d.lastSeenAt,
      pushToken: d.pushToken,
      pushPlatform: d.pushPlatform,
      presence: d.presence,
      relayUrl: d.relayUrl,
      relayMoveTo: d.relayMoveTo,
      relayMovedFrom: d.relayMovedFrom,
      relayMoveSettled: d.relayMoveSettled,
    ),
  );

  @override
  void updatePush(
    String id, {
    required String token,
    required String platform,
    CompanionPresence presence = CompanionPresence.unknown,
    DateTime? now,
  }) => _update(
    id,
    (d) => d.copyWith(
      pushToken: token,
      pushPlatform: platform,
      presence: CompanionPresence(
        deviceKind: presence.deviceKind,
        visibility: presence.visibility,
        focusedSessionId: presence.focusedSessionId,
        at: now ?? DateTime.now().toUtc(),
      ),
    ),
  );

  @override
  void delete(String id) => _rows.remove(id);

  @override
  void askRelayMove(String id, String? to) => _update(
    id,
    (d) => _moved(
      d,
      relayUrl: d.relayUrl,
      moveTo: to,
      settled: d.relayMoveSettled,
    ),
  );

  @override
  void moveRelay(String id, String to) => _update(
    id,
    (d) => d.relayUrl == to
        ? d
        : _moved(d, relayUrl: to, movedFrom: d.relayUrl, settled: false),
  );

  @override
  void settleRelayMove(String id) => _update(
    id,
    (d) => _moved(
      d,
      relayUrl: d.relayUrl,
      moveTo: d.relayMoveTo,
      movedFrom: d.relayMovedFrom,
    ),
  );

  static PairedDevice _moved(
    PairedDevice d, {
    required String? relayUrl,
    String? moveTo,
    String? movedFrom,
    bool settled = true,
  }) => PairedDevice(
    id: d.id,
    name: d.name,
    deviceKey: d.deviceKey,
    capabilities: d.capabilities,
    generation: d.generation,
    createdAt: d.createdAt,
    revoked: d.revoked,
    lastSeenAt: d.lastSeenAt,
    pushToken: d.pushToken,
    pushPlatform: d.pushPlatform,
    presence: d.presence,
    relayUrl: relayUrl,
    relayMoveTo: moveTo,
    relayMovedFrom: movedFrom ?? d.relayMovedFrom,
    relayMoveSettled: settled,
  );
}
