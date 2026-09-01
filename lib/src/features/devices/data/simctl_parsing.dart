import 'dart:convert';

import '../domain/ios_simulator.dart';

/// Parses `xcrun simctl list devices -j`.
///
/// JSON rather than the plain-text listing on purpose. The text form groups
/// devices under `-- iOS 26.4 --` headers and pads names to align a column,
/// which makes every name ambiguous the moment one contains two spaces; the
/// JSON form names the runtime as a key and needs no scanning at all.
///
/// Tolerant in the same way the adb parsers are: a malformed document, an
/// entry missing a udid, or a runtime whose value is not a list is skipped
/// rather than thrown over. A simulator list is a convenience, and one bad row
/// must not cost the user the other twenty.
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

/// Pixel dimensions from `xcrun simctl io <udid> enumerate`.
///
/// The output is an indented tree of display descriptors; the numbers wanted
/// are the first `width`/`height` pair under a display, which is the internal
/// screen. Returns null when the shape is not recognised, which reads as "ask
/// something else" rather than as a guess.
({int width, int height})? parseSimctlScreenSize(String output) {
  int? width;
  int? height;
  for (final line in output.split('\n')) {
    final trimmed = line.trim();
    final match = RegExp(r'^(width|height):\s*(\d+)$').firstMatch(trimmed);
    if (match == null) continue;
    final value = int.tryParse(match.group(2)!);
    if (value == null || value <= 0) continue;
    if (match.group(1) == 'width') {
      width ??= value;
    } else {
      height ??= value;
    }
    if (width != null && height != null) return (width: width, height: height);
  }
  return null;
}
