part of '../data_change.dart';

// Who drives which device on the server's machine (slice 4a), told to every
// desktop client.

DataChange? _devicesChangeFromJson(String name, Map<String, Object?> json) =>
    switch (name) {
      'deviceClaimsChanged' => DeviceClaimsChanged([
        for (final hold in json['holds']! as List)
          DeviceHold.fromJson((hold as Map).cast<String, Object?>()),
      ]),
      _ => null,
    };

/// Every claim the server's registry holds, whole — a handful of devices. Told
/// when a claim is taken, released, lapses or its holder is renamed, and to a
/// subscriber on arrival.
final class DeviceClaimsChanged extends RunsChange {
  const DeviceClaimsChanged(this.holds);

  final List<DeviceHold> holds;

  @override
  Map<String, Object?> toJson() => {
    'change': 'deviceClaimsChanged',
    'holds': [for (final hold in holds) hold.toJson()],
  };
}
