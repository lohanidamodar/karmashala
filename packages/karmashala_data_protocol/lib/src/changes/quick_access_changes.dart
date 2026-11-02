part of '../data_change.dart';

// The quick-access pins, whole: a short list, told after every change and to
// a client that subscribes, so every browser on every client shows the same.

DataChange? _quickAccessChangeFromJson(
  String name,
  Map<String, Object?> json,
) => switch (name) {
  'quickAccessChanged' => QuickAccessChanged([
    for (final item in json['pins']! as List)
      QuickAccessPin.fromJson((item as Map).cast<String, Object?>()),
  ]),
  'operateByDefaultChanged' => OperateByDefaultChanged(
    enabled: json['enabled'] == true,
  ),
  _ => null,
};

/// "Let new sessions operate Karmashala" as it now stands. A client that
/// subscribes is told it only while it is on: silence means off.
final class OperateByDefaultChanged extends DataChange {
  const OperateByDefaultChanged({required this.enabled});

  final bool enabled;

  @override
  Map<String, Object?> toJson() => {
    'change': 'operateByDefaultChanged',
    'enabled': enabled,
  };
}

/// Every pinned folder, in order, as it now stands.
final class QuickAccessChanged extends DataChange {
  const QuickAccessChanged(this.pins);

  final List<QuickAccessPin> pins;

  @override
  Map<String, Object?> toJson() => {
    'change': 'quickAccessChanged',
    'pins': [for (final pin in pins) pin.toJson()],
  };
}
