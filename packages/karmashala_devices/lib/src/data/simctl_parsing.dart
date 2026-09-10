import 'dart:convert';

import '../domain/ios_simulator.dart';

/// Parses `xcrun simctl list devices -j`. JSON rather than the plain-text
/// listing, which pads names to align a column and so makes any name with two
/// spaces ambiguous. Tolerant like the adb parsers: one bad row is skipped.
List<IosSimulator> parseSimctlDevices(String json) {
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return const [];
  }
  if (decoded is! Map<String, Object?>) return const [];
  final devices = decoded['devices'];
  if (devices is! Map<String, Object?>) return const [];

  final simulators = <IosSimulator>[];
  for (final entry in devices.entries) {
    final list = entry.value;
    if (list is! List) continue;
    for (final row in list) {
      if (row is! Map<String, Object?>) continue;
      final udid = row['udid'];
      final name = row['name'];
      if (udid is! String || udid.isEmpty) continue;
      if (name is! String || name.isEmpty) continue;
      final size = row['dataPathSize'];
      simulators.add(
        IosSimulator(
          udid: udid,
          name: name,
          state: SimulatorState.parse(
            row['state'] is String ? row['state']! as String : '',
          ),
          runtime: entry.key,
          deviceTypeIdentifier: row['deviceTypeIdentifier'] is String
              ? row['deviceTypeIdentifier']! as String
              : '',
          // Absent means available: `simctl` omits the key for a healthy
          // device on some versions and sets it false on others.
          isAvailable: row['isAvailable'] is bool
              ? row['isAvailable']! as bool
              : true,
          dataPathSize: size is int ? size : null,
        ),
      );
    }
  }
  return simulators;
}

/// Pixel dimensions of the device's own screen, from
/// `simctl io <udid> enumerate`. **The first width/height pair in the output is
/// not the phone** — a booted iPhone enumerates a 720x480 `Display class: 1`
/// beside it — so the internal display is selected by `Display class: 0`. These
/// are **pixels**; taps are in points, three times smaller on a 3x device.
({int width, int height})? parseSimctlScreenSize(String output) {
  ({int width, int height, int displayClass})? best;

  for (final block in output.split(RegExp(r'\n\s*\n'))) {
    if (!block.contains('Class: Display')) continue;
    final width = _intAfter(block, 'Default width');
    final height = _intAfter(block, 'Default height');
    if (width == null || height == null) continue;
    if (width <= 0 || height <= 0) continue;
    final displayClass = _intAfter(block, 'Display class') ?? -1;
    // The internal screen, whatever else is attached.
    if (displayClass == 0) return (width: width, height: height);
    if (best == null || width * height > best.width * best.height) {
      best = (width: width, height: height, displayClass: displayClass);
    }
  }
  if (best == null) return null;
  return (width: best.width, height: best.height);
}

int? _intAfter(String block, String label) {
  final match = RegExp(
    '^\\s*${RegExp.escape(label)}:\\s*(\\d+)\\s*\$',
    multiLine: true,
  ).firstMatch(block);
  return match == null ? null : int.tryParse(match.group(1)!);
}
