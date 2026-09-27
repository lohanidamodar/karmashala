import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_device_pane/widgets.dart';
import 'package:karmashala_ui/primitives.dart';

/// Every spinner in the device surfaces is the house [InlineSpinner]: eight
/// hand-built `SizedBox` + `CircularProgressIndicator` copies had drifted to
/// 14, 16, 20 and Material's own 36px.
void main() {
  test('no presentation file builds its own progress ring', () {
    final offenders = <String>[];
    for (final file in Directory(
      'lib/src/presentation',
    ).listSync().whereType<File>()) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].contains('CircularProgressIndicator(')) {
          offenders.add('${file.path}:${i + 1}');
        }
      }
    }
    expect(offenders, isEmpty, reason: 'use InlineSpinner');
  });

  testWidgets('the reconnecting overlay spins at the region size', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: StreamReconnectingOverlay(deviceLabel: 'Pixel')),
      ),
    );
    final spinner = tester.widget<InlineSpinner>(find.byType(InlineSpinner));
    expect(spinner.size, InlineSpinnerSize.large);
  });
}
