import 'package:chitragupta/src/app/theme/app_theme.dart';
import 'package:chitragupta/src/app/theme/design_tokens.dart';
import 'package:chitragupta/src/features/verification/domain/verdict_attribution.dart';
import 'package:chitragupta/src/features/verification/presentation/attribution_mark.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The mark is the single place the three states become words and a colour.
/// These tests pin that mapping, because the failure mode it exists to prevent
/// is two surfaces reading the same fact differently.
void main() {
  late BuildContext captured;

  Future<void> pump(WidgetTester tester, VerdictAttribution attribution) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              captured = context;
              return AttributionMark(attribution: attribution);
            },
          ),
        ),
      ),
    );
  }

  Color renderedColour(WidgetTester tester) =>
      tester.widget<Text>(find.byType(Text)).style!.color!;

  testWidgets('a self-graded verdict is marked, and marked as a caution', (
    tester,
  ) async {
    await pump(tester, VerdictAttribution.author);

    expect(find.text('self'), findsOneWidget);
    // The attention colour, not the healthy one: a candidate's own account of
    // itself is the thing worth a second look.
    expect(renderedColour(tester), SemanticColors.of(captured).attention);
  });

  testWidgets('a verdict from another session reads as independent', (
    tester,
  ) async {
    await pump(tester, VerdictAttribution.independent);

    expect(find.text('independent'), findsOneWidget);
    expect(renderedColour(tester), SemanticColors.of(captured).idle);
  });

  testWidgets('an unrecorded verifier is a visible gap, never an empty one', (
    tester,
  ) async {
    await pump(tester, VerdictAttribution.notRecorded);

    // The robustness bar: unknown attribution must still say something. A
    // blank here would read as "verified" to anyone scanning the row.
    final text = tester.widget<Text>(find.byType(Text));
    expect(text.data, isNotEmpty);
    expect(find.text('unattributed'), findsOneWidget);
    expect(renderedColour(tester), SemanticColors.of(captured).neutral);
  });

  testWidgets('every state names itself in full on hover', (tester) async {
    for (final attribution in VerdictAttribution.values) {
      await pump(tester, attribution);
      expect(
        tester.widget<Tooltip>(find.byType(Tooltip)).message,
        attribution.label,
      );
    }
  });
}
