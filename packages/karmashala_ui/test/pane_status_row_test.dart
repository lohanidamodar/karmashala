import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/panes.dart';

import 'support/layout_probe.dart';

/// The line at the top of the browser pane and the Flutter app pane: a dot,
/// what is attached, one action. Moved here from the browser feature, which
/// the Flutter pane had been importing it from.
void main() {
  const label =
      'Attached to http://127.0.0.1:52341/aBcDeFgHiJk=/ — my_app (debug)';

  Widget row({String? tooltip}) => PaneStatusRow(
    color: const Color(0xFF1F7A3D),
    label: label,
    tooltip: tooltip,
    action: TextButton(onPressed: () {}, child: const Text('Detach')),
  );

  for (final width in [200.0, 240.0, 400.0]) {
    for (final scale in sweepScales) {
      testWidgets('fits ${width.toInt()}px at ${scale}x', (tester) async {
        final overflows = await pumpInBox(
          tester,
          width: width,
          textScale: scale,
          child: row(),
        );
        expect(overflows, isEmpty);
      });
    }
  }

  testWidgets('the action takes half the row at most', (tester) async {
    await pumpInBox(tester, width: 240, textScale: 2, child: row());
    expect(
      // As painted: the action scales down rather than wrapping.
      tester.getRect(find.byType(TextButton)).width,
      lessThanOrEqualTo(120),
    );
  });

  testWidgets('the dot is labelled once, by the text beside it', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpInBox(tester, width: 400, child: row());
    expect(find.byType(StatusDot), findsOneWidget);
    expect(find.bySemanticsLabel(label), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a tooltip wraps the label when given', (tester) async {
    await pumpInBox(tester, width: 400, child: row(tooltip: 'VM service'));
    expect(find.byTooltip('VM service'), findsOneWidget);
    await pumpInBox(tester, width: 400, child: row());
    expect(find.byType(Tooltip), findsNothing);
  });
}
