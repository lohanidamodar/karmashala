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

/// Pixel dimensions of the device's own screen, from
/// `xcrun simctl io <udid> enumerate`.
///
/// The output is a list of `Port:` blocks, and **the first width/height pair in
/// it is not the phone**. A booted iPhone 17 Pro enumerates two displays: one
/// at 720x480 with `Display class: 1`, and the real screen at 1206x2622 with
/// `Display class: 0`. Taking the first pair — or the first `width:` line
/// anywhere, which also matches the `IOSurface port:` sub-block — reports a
/// 720x480 phone, and every coordinate derived from it is wrong.
///
/// So the internal display is selected by `Display class: 0`, falling back to
/// the largest display when no block declares one, and `null` when the output
/// is not this shape at all.
///
/// These are **pixels**. `idb ui describe-all` reports frames, and takes taps,
/// in points; on a 3x device the two differ by a factor of three.
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
