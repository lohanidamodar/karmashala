import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

/// The `resumes 14:05` clause of a session row. Under a thumb it is first on
/// the card's where-line, behind a clock, so it is what survives a narrow
/// screen; under a pointer the row is one line (spec §2.4) and the clause
/// leads the title's hover instead.
void main() {
  Widget host(
    Widget child, {
    required double width,
    double textScale = 1,
    bool touch = true,
  }) => MaterialApp(
    theme: AppTheme.light().copyWith(
      platform: touch ? TargetPlatform.android : TargetPlatform.windows,
    ),
    builder: (context, inner) => UiDensity.wrap(context, inner!),
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

  /// The card's where-line: the branch, and what is due before it.
  String whereLine(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((text) => text.textSpan?.toPlainText() ?? text.data ?? '')
      .firstWhere((text) => text.contains('feature/a-rather'));

  testWidgets('leads the where-line, behind a clock, with the rest after it', (
    tester,
  ) async {
    await tester.pumpWidget(host(card(), width: 320));
    expect(find.byIcon(AppIcons.clock), findsOneWidget);
    final line = whereLine(tester);
    expect(
      line.indexOf('resumes 14:05'),
      lessThan(line.indexOf('feature/a-rather')),
    );
    expect(find.byTooltip(RegExp('then sends "continue"')), findsWidgets);
  });

  testWidgets('a row with nothing scheduled draws no clock', (tester) async {
    await tester.pumpWidget(host(card(scheduled: null), width: 320));
    expect(find.byIcon(AppIcons.clock), findsNothing);
    expect(whereLine(tester), isNot(contains('resumes')));
  });

  testWidgets('under a pointer it leads the title\'s hover, and is not drawn', (
    tester,
  ) async {
    await tester.pumpWidget(host(card(), width: 320, touch: false));
    expect(find.byIcon(AppIcons.clock), findsNothing);
    final hover = tester
        .widgetList<Tooltip>(find.byType(Tooltip))
        .map((tip) => tip.message ?? '')
        .firstWhere((message) => message.contains('Codex CLI'));
    expect(hover, contains('resumes 14:05  ·  Codex CLI  ·  idle'));
    expect(hover, contains('then sends "continue"'));
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
                (widget.textSpan?.toPlainText() ?? widget.data ?? '').contains(
                  'resumes',
                ),
          ),
        );
        expect(text.overflow, TextOverflow.ellipsis);
        expect(text.maxLines, 1);
      });
    }
  }
}
