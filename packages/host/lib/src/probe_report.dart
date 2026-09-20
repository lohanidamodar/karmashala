/// The shape every `probe-*` command prints, in one place: a deployer greps
/// these lines, so the two probes must not drift apart in how they spell them.
library;

import 'dart:io';

/// This machine's architecture, off the Dart version string. A reading, not a
/// compile-time constant — a binary can be run on something it was not built on.
String get hostArchitecture {
  final match = RegExp(r'"[a-z]+_([a-z0-9]+)"').firstMatch(Platform.version);
  return match?.group(1) ?? 'unknown';
}

/// The first line of every probe.
String probeHeader() =>
    'host      ${Platform.operatingSystem} $hostArchitecture';

/// One checked fact. The name column is five wide so `ok` and `FAIL` align.
String probeStep(String name, bool ok, [String detail = '']) =>
    '${ok ? 'ok  ' : 'FAIL'} $name${detail.isEmpty ? '' : '  $detail'}';

/// A fact worth printing that nothing checked. Kept distinct from [probeStep]
/// on purpose: a value in the shape of a check reads as a check that passed.
String probeNote(String name, String value) => '${name.padRight(9)} $value';
