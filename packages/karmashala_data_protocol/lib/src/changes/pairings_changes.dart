part of '../data_change.dart';

// Paired devices. A device's key, generation and push token are secrets:
// never in a change (`pairedDeviceToJson`).

DataChange? _pairingsChangeFromJson(
  String name,
  Map<String, Object?> json,
) => switch (name) {
  'deviceChanged' => DeviceChanged(pairedDeviceFromJson(_row(json))),
  'deviceRemoved' => DeviceRemoved(json['id']! as String),
  _ => null,
};

/// A change to the paired devices.
sealed class PairingsChange extends DataChange {
  const PairingsChange();
}

/// A device paired, renamed, granted, revoked or seen, **without secrets**.
final class DeviceChanged extends PairingsChange {
  const DeviceChanged(this.device);

  final PairedDevice device;

  @override
  Map<String, Object?> toJson() => {
    'change': 'deviceChanged',
    'row': pairedDeviceToJson(device),
  };
}

final class DeviceRemoved extends PairingsChange {
  const DeviceRemoved(this.id);

  final String id;

  @override
  Map<String, Object?> toJson() => {'change': 'deviceRemoved', 'id': id};
}
