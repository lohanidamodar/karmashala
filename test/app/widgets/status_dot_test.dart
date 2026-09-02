import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/theme/app_theme.dart';
import 'package:karmashala/src/app/theme/design_tokens.dart';
import 'package:karmashala/src/app/widgets/status_dot.dart';

import '../../support/window_matrix.dart';

/// The dot that cannot be unlabelled.
///
/// The bug this widget exists to make unwriteable: four distinct states carried
/// in colour alone, with no glyph, no tooltip and nothing in the semantics
/// tree. `label` being required is the compile-time half of the guarantee; what
/// is checked here is the other half — that the label actually reaches the tree
/// Narrator reads, and that an empty one is rejected rather than accepted as a
/// technicality.
void main() {
  Widget host(Widget child) => MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(body: Center(child: child)),
  );

  testWidgets('the label reaches the semantics tree', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      host(
        StatusDot(
          color: SemanticColors.forBrightness(Brightness.light).failure,
          label: 'Run failed',
        ),
      ),
    );

    expect(find.bySemanticsLabel('Run failed'), findsOneWidget);
    handle.dispose();
  });

  test('it is dumb, and const-constructible', () {
    // Same rule as PaneHeader: a dot drawn in six places must not subscribe on
    // its callers' behalf, and holding one must cost nothing.
    const dot = StatusDot(color: Color(0xFF000000), label: 'Failed');
    expect(dot, isA<StatelessWidget>());
    expect(dot, isNot(isA<ConsumerWidget>()));
  });

  test('an empty label is rejected at construction', () {
    expect(
      () => StatusDot(color: const Color(0xFF000000), label: ''),
      throwsA(isA<AssertionError>()),
    );
  });

  testWidgets('it is exactly Chrome.dot across, ring or no ring', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            StatusDot(
              color: SemanticColors.forBrightness(Brightness.light).idle,
              label: 'Healthy',
            ),
            StatusDot(
              color: SemanticColors.forBrightness(Brightness.light).attention,
              label: '3 waiting',
              ring: AppTheme.light().colorScheme.surfaceContainerLow,
            ),
          ],
        ),
      ),
    );

    for (final size in tester
        .widgetList<StatusDot>(find.byType(StatusDot))
        .map((dot) => tester.getSize(find.byWidget(dot)))) {
      // The ring is drawn inside the box: a haloed dot takes no more room.
      expect(size, const Size(Chrome.dot, Chrome.dot));
    }
  });

  testWidgets('a tooltip is optional, so it cannot hide an outer one', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        StatusDot(
          color: SemanticColors.forBrightness(Brightness.light).working,
          label: 'Working',
        ),
      ),
    );
    expect(find.byType(Tooltip), findsNothing);

    await tester.pumpWidget(
      host(
        StatusDot(
          color: SemanticColors.forBrightness(Brightness.light).working,
          label: 'Working',
          tooltip: 'The agent is mid-turn',
        ),
      ),
    );
    expect(
      tester.widget<Tooltip>(find.byType(Tooltip)).message,
      'The agent is mid-turn',
    );
  });

  testWidgets('it survives the window matrix', (tester) async {
    await expectSurvivesWindowMatrix(
      tester,
      build: () => host(
        StatusDot(
          color: SemanticColors.forBrightness(Brightness.light).attention,
          label: '3 waiting',
          tooltip: 'Three things are waiting for you',
        ),
      ),
      // Nothing here is focusable: a dot is a readout, not a control.
      checkFocus: false,
      because: 'a fixed 7px dot must not grow with the text scaler',
    );
  });
}
