import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';

import 'support/layout_probe.dart';

/// The strip under a pane's header that a master/detail pane draws for its own
/// level — "3 runs", or a back button and the run's title. The verification
/// pane drew it privately.
void main() {
  Widget toolbar({bool withLeading = true}) => PaneSubToolbar(
    title: 'A verification run with a title far longer than the side panel',
    leading: withLeading
        ? IconButton(
            iconSize: Chrome.icon,
            visualDensity: VisualDensity.compact,
            tooltip: 'Back',
            icon: const Icon(AppIcons.arrowLeft),
            onPressed: () {},
          )
        : null,
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final glyph in [AppIcons.article, AppIcons.copy, AppIcons.trash])
          IconButton(
            iconSize: Chrome.icon,
            visualDensity: VisualDensity.compact,
            tooltip: 'Action',
            icon: Icon(glyph),
            onPressed: () {},
          ),
      ],
    ),
  );

  for (final width in [240.0, 360.0]) {
    for (final scale in sweepScales) {
      testWidgets('fits ${width.toInt()}px at ${scale}x', (tester) async {
        final overflows = await pumpInBox(
          tester,
          width: width,
          textScale: scale,
          child: toolbar(),
        );
        expect(overflows, isEmpty);
      });
    }
  }

  testWidgets('is a tab-strip row and a hairline at the default text size', (
    tester,
  ) async {
    await pumpInBox(tester, width: 360, child: toolbar());
    expect(
      tester.getSize(find.byType(PaneSubToolbar)).height,
      Chrome.tabStrip + 1,
    );
    expect(find.byType(Divider), findsOneWidget);
  });

  testWidgets('the leading slot comes first; without one the title is inset', (
    tester,
  ) async {
    await pumpInBox(tester, width: 360, child: toolbar());
    final back = tester.getRect(find.byTooltip('Back'));
    final title = tester.getRect(find.textContaining('A verification run'));
    expect(back.right, lessThanOrEqualTo(title.left));

    await pumpInBox(tester, width: 360, child: toolbar(withLeading: false));
    expect(
      tester.getRect(find.textContaining('A verification run')).left,
      Insets.md,
    );
  });

  testWidgets('never wears the close action a PaneHeader would', (
    tester,
  ) async {
    await pumpInBox(
      tester,
      width: 360,
      child: PaneCloseAction(
        tooltip: 'Close verification',
        onClose: () {},
        child: toolbar(),
      ),
    );
    expect(find.byTooltip('Close verification'), findsNothing);
  });
}
