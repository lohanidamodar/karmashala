part of '../data_request.dart';

// Paired devices (phones and other clients). Every device travels without
// its key, generation or push token (`pairedDeviceToJson`).

DataRequest<Object?>? _pairingsRequestFromJson(String kind, _Arguments args) =>
    switch (kind) {
      DevicesList.name => const DevicesList(),
      DeviceRename.name => DeviceRename(args.string('id'), args.string('name')),
      DeviceGrant.name => DeviceGrant(
        args.string('id'),
        CapabilitySet(args.integer('capabilities')),
      ),
      DeviceRevoke.name => DeviceRevoke(args.string('id')),
      _ => null,
    };

/// A paired-devices request: the list, or a change a person makes to one.
sealed class PairingsRequest<R> extends DataRequest<R> {
  const PairingsRequest();
}

/// Every paired device, revoked ones included, newest first.
final class DevicesList extends PairingsRequest<List<PairedDevice>> {
  const DevicesList();

  static const String name = 'devices.list';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};

  @override
  Object? resultToJson(List<PairedDevice> result) => [
    for (final device in result) pairedDeviceToJson(device),
  ];

  @override
  List<PairedDevice> resultFromJson(Object? json) => _decode(
    kind,
    () => [for (final item in _objects(json, kind)) pairedDeviceFromJson(item)],
  );
}

/// A write to one device, answered with it as it now stands.
sealed class _DeviceWrite extends PairingsRequest<PairedDevice> {
  const _DeviceWrite(this.id);

  final String id;

  @override
  Object? resultToJson(PairedDevice result) => pairedDeviceToJson(result);

  @override
  PairedDevice resultFromJson(Object? json) =>
      _decode(kind, () => pairedDeviceFromJson(_object(json, kind)));
}

/// What a person calls device [id]. Refused for a blank name.
final class DeviceRename extends _DeviceWrite {
  const DeviceRename(super.id, this.deviceName);

  static const String name = 'devices.rename';

  final String deviceName;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id, 'name': deviceName};
}

/// What device [id] may do from now on, applied to its live link too.
/// Refused for a revoked device.
final class DeviceGrant extends _DeviceWrite {
  const DeviceGrant(super.id, this.capabilities);

  static const String name = 'devices.grant';

  final CapabilitySet capabilities;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'id': id,
    'capabilities': capabilities.bits,
  };
}

/// Revokes device [id]: its key is deleted and its live links dropped.
final class DeviceRevoke extends _DeviceWrite {
  const DeviceRevoke(super.id);

  static const String name = 'devices.revoke';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id};
}
