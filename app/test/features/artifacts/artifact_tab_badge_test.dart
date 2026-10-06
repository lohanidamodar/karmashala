import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/artifacts/presentation/artifact_count_badge.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_tab_chip.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:karmashala_ui/theme.dart';

/// A terminal tab whose session has shown artifacts says how many, so a
/// person working in the terminal view knows there is something to open.
void main() {
  Future<void> pump(WidgetTester tester, {required double width}) =>
      tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: TerminalTabChip(
                  title: 'Chart the coverage',
                  liveness: PaneLiveness.live,
                  selected: true,
                  index: 0,
                  tabCount: 1,
                  onTap: () {},
                  onClose: () {},
                  onEnd: () {},
                  onBulkClose: (_) {},
                  badge: const ArtifactCountBadge(count: 3),
                ),
              ),
            ),
          ),
        ),
      );

  testWidgets('the tab carries the count, and says what it counts', (
    tester,
  ) async {
    await pump(tester, width: 220);
    expect(find.byKey(const ValueKey('artifact-count-badge')), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.byTooltip('3 artifacts shown in this session'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a tab too narrow for it drops the count, not the title', (
    tester,
  ) async {
    await pump(tester, width: 90);
    expect(find.byKey(const ValueKey('artifact-count-badge')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
