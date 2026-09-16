import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The device surfaces take their spacing and sizes from `Insets`, `Chrome`
/// and `DialogWidth`, not from numbers written inline — ~62 of them had
/// drifted into `lib/src/presentation`.
///
/// Allowed: 0, 1 and 2 (hairlines and a baseline nudge, which no scale step
/// names), and any value given a name of its own (`static const x = 220.0`),
/// because a name says why.
void main() {
  test('no presentation file writes a spacing or size as a bare number', () {
    final inline = RegExp(
      r'(horizontal|vertical|left|right|top|bottom|height|width|size|spacing'
      r'|runSpacing): ([3-9]|[1-9][0-9]+)(\.[0-9]+)?[,)]'
      r'|EdgeInsets\.(all|fromLTRB)\([^)]*\b([3-9]|[1-9][0-9]+)\b',
    );
    final offenders = <String>[];
    for (final file in Directory(
      'lib/src/presentation',
    ).listSync().whereType<File>()) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (inline.hasMatch(lines[i])) {
          offenders.add('${file.path}:${i + 1}: ${lines[i].trim()}');
        }
      }
    }
    expect(offenders, isEmpty, reason: 'use Insets / Chrome / DialogWidth');
  });
}
