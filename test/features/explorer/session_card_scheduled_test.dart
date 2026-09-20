import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/theme.dart';

/// The `resumes 14:05` clause of a session row: first on its line, behind a
/// clock, so it is what survives when the pane is dragged to its minimum.
void main() {
  Widget host(Widget child, {required double width, double textScale = 1}) =>
      MaterialApp(
        theme: AppTheme.light(),
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: Scaffold(
            body: SizedBox(width: width, child: child),
          ),
        ),
      );

  SessionCard card({String? scheduled = 'resumes 14:05'}) => SessionCard(
    depth: 1,
    selected: false,
    agentIcon: AppIcons.playCircle,
    agentLabel: 'Codex CLI  ·  idle',
    title: 'Port the importer',
    age: '22m',
    branch: 'feature/a-rather-long-branch-name',
    whereabouts: 'last seen 2h ago',
    scheduled: scheduled,
    scheduledTooltip:
        'Resumes 14:05, when the 5-hour window resets, then sends "continue".',
    onTap: () {},
    menuItemsBuilder: () => const [],
    onMenu: (_) {},
  );

  String metaLine(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((text) => text.textSpan?.toPlainText() ?? text.data ?? '')
      .firstWhere((text) => text.contains('Codex CLI'));

  testWidgets('leads the meta line, behind a clock, with the rest after it', (
    tester,
  ) async {
    await tester.pumpWidget(host(card(), width: 320));
    expect(find.byIcon(AppIcons.clock), findsOneWidget);
    final line = metaLine(tester);
    expect(line.indexOf('resumes 14:05'), lessThan(line.indexOf('Codex CLI')));
    expect(find.byTooltip(RegExp('then sends "continue"')), findsOneWidget);
  });

  testWidgets('a row with nothing scheduled draws no clock', (tester) async {
    await tester.pumpWidget(host(card(scheduled: null), width: 320));
    expect(find.byIcon(AppIcons.clock), findsNothing);
    expect(metaLine(tester), isNot(contains('resumes')));
  });

  for (final width in [200.0, 240.0]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets('nothing overflows at ${width.round()}px, text x$scale, and '
          'the time is still in the line', (tester) async {
        await tester.pumpWidget(host(card(), width: width, textScale: scale));
        expect(tester.takeException(), isNull);
        expect(find.byIcon(AppIcons.clock), findsOneWidget);
        final text = tester.widget<Text>(
          find.byWidgetPredicate(
            (widget) =>
                widget is Text &&
                (widget.textSpan?.toPlainText() ?? '').contains('resumes'),
          ),
        );
        expect(text.overflow, TextOverflow.ellipsis);
        expect(text.maxLines, 1);
      });
    }
  }
}
