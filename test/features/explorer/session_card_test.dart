import 'package:chitragupta/src/app/theme/app_icons.dart';
import 'package:chitragupta/src/app/theme/app_theme.dart';
import 'package:chitragupta/src/features/explorer/application/session_diff_stat.dart';
import 'package:chitragupta/src/features/explorer/presentation/session_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The three-line session card.
///
/// Two things these tests exist to hold, both of which the old one-line row
/// got wrong at some point:
///
/// * a long title or a long branch **truncates**; it never overflows. Loop 46
///   already hit this once when the subtitle grew, and a pane whose width the
///   user drags is exactly where it happens.
/// * an age is coarse. A card that renders `0m` — or counts seconds — looks
///   live when nothing is.
void main() {
  group('compactAge', () {
    test('rounds down, and never counts seconds', () {
      expect(compactAge(const Duration(seconds: 4)), 'now');
      expect(compactAge(const Duration(seconds: 59)), 'now');
      expect(compactAge(const Duration(minutes: 3)), '3m');
      expect(compactAge(const Duration(minutes: 22)), '22m');
      expect(compactAge(const Duration(minutes: 59)), '59m');
    });

    test('carries minutes into the hour, as MonoCode does', () {
      expect(compactAge(const Duration(hours: 7, minutes: 59)), '7h 59m');
      expect(compactAge(const Duration(hours: 10, minutes: 58)), '10h 58m');
      expect(compactAge(const Duration(hours: 3)), '3h');
    });

    test('caps at days plus hours', () {
      expect(compactAge(const Duration(days: 2, hours: 4)), '2d 4h');
      expect(compactAge(const Duration(days: 9)), '9d');
    });

    test('a clock that ran backwards is not a negative age', () {
      expect(compactAge(const Duration(minutes: -5)), 'now');
    });
  });

  group('SessionDiffStat', () {
    test('is empty when there is nothing worth drawing', () {
      expect(SessionDiffStat.unknown.isEmpty, isTrue);
      expect(
        const SessionDiffStat(branch: 'main', changedFiles: 0).isEmpty,
        isTrue,
      );
      expect(const SessionDiffStat(changedFiles: 3).isEmpty, isFalse);
      expect(const SessionDiffStat(commitsAhead: 2).isEmpty, isFalse);
    });

    test('line counts are the declared seam, and are absent today', () {
      expect(SessionDiffStat.unknown.hasLineCounts, isFalse);
      const filled = SessionDiffStat(added: 949, removed: 10);
      expect(filled.hasLineCounts, isTrue);
      expect(filled.isEmpty, isFalse);
    });
  });

  Widget host(Widget child, {double width = 320}) => MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(
      body: SizedBox(width: width, child: child),
    ),
  );

  SessionCard card({
    String title = 'Benchmark arcade games',
    String? branch = 'monocode/main',
    String? whereabouts,
    String? age = '22m',
    SessionDiffStat? stat,
    bool worktree = false,
    bool selected = false,
  }) => SessionCard(
    depth: 1,
    selected: selected,
    agentIcon: AppIcons.playCircle,
    agentLabel: 'Claude Code  ·  running',
    title: title,
    age: age,
    branch: branch,
    whereabouts: whereabouts,
    stat: stat,
    worktree: worktree,
    onTap: () {},
    menuItems: const [],
    onMenu: (_) {},
  );

  testWidgets('draws three lines: who and when, what, and where', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        card(
          whereabouts: 'opened in an external terminal',
          stat: const SessionDiffStat(branch: 'feature/x', changedFiles: 6),
        ),
      ),
    );

    expect(find.text('Claude Code  ·  running'), findsOneWidget);
    expect(find.text('22m'), findsOneWidget);
    expect(find.text('Benchmark arcade games'), findsOneWidget);
    expect(
      find.text('monocode/main  ·  opened in an external terminal'),
      findsOneWidget,
    );
    expect(find.text('6 changed'), findsOneWidget);

    // Line order, top to bottom — the whole point of the shape.
    final agent = tester.getTopLeft(find.text('Claude Code  ·  running')).dy;
    final title = tester.getTopLeft(find.text('Benchmark arcade games')).dy;
    final where = tester.getTopLeft(find.text('6 changed')).dy;
    expect(agent, lessThan(title));
    expect(title, lessThan(where));
  });

  testWidgets('the age and the diff stat sit on the right edge', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(card(stat: const SessionDiffStat(changedFiles: 2))),
    );
    final cardRight = tester.getBottomRight(find.byType(SessionCard)).dx;
    expect(
      tester.getBottomRight(find.text('22m')).dx,
      greaterThan(cardRight - 40),
    );
    expect(
      tester.getBottomRight(find.text('2 changed')).dx,
      greaterThan(cardRight - 90),
    );
  });

  testWidgets('a very long title truncates rather than overflowing', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        card(
          title:
              'Rewrite the entire notification pipeline and every one of its '
              'nineteen policy cases, then document what it decided not to say',
        ),
        width: 240,
      ),
    );
    expect(tester.takeException(), isNull);
    final text = tester.widget<Text>(
      find.textContaining('Rewrite the entire notification'),
    );
    expect(text.overflow, TextOverflow.ellipsis);
    expect(text.maxLines, 1);
  });

  testWidgets('a very long branch and whereabouts truncate at a narrow pane', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        card(
          branch: 'feature/very-long-branch-name-that-nobody-should-have-typed',
          whereabouts: 'opened in an external terminal',
          stat: const SessionDiffStat(changedFiles: 12),
        ),
        // Narrower than the Explorer's own 200px minimum, deliberately.
        width: 190,
      ),
    );
    expect(tester.takeException(), isNull);
    // The stat keeps its width; the branch line is the part that gives way.
    expect(find.text('12 changed'), findsOneWidget);
    final where = tester.widget<Text>(
      find.textContaining('feature/very-long-branch-name'),
    );
    expect(where.overflow, TextOverflow.ellipsis);
  });

  testWidgets('line counts replace the file count once something sets them', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        card(
          stat: const SessionDiffStat(changedFiles: 6, added: 949, removed: 10),
        ),
      ),
    );
    expect(find.text('+949'), findsOneWidget);
    expect(find.text('−10'), findsOneWidget);
    expect(find.text('6 changed'), findsNothing);
  });

  testWidgets('commits ahead show beside the change count', (tester) async {
    await tester.pumpWidget(
      host(card(stat: const SessionDiffStat(changedFiles: 1, commitsAhead: 3))),
    );
    expect(find.text('↑3'), findsOneWidget);
    expect(find.text('1 changed'), findsOneWidget);
  });

  testWidgets('a card with nothing to say on line three does not draw one', (
    tester,
  ) async {
    await tester.pumpWidget(host(card(branch: null, stat: null)));
    expect(find.byIcon(AppIcons.gitBranch), findsNothing);
    final tall = tester.getSize(find.byType(SessionCard)).height;

    await tester.pumpWidget(
      host(card(stat: const SessionDiffStat(changedFiles: 4))),
    );
    expect(tester.getSize(find.byType(SessionCard)).height, greaterThan(tall));
  });

  testWidgets('the worktree glyph appears only for a worktree session', (
    tester,
  ) async {
    await tester.pumpWidget(host(card()));
    expect(find.byIcon(AppIcons.treeStructure), findsNothing);

    await tester.pumpWidget(host(card(worktree: true)));
    expect(find.byIcon(AppIcons.treeStructure), findsOneWidget);
  });

  testWidgets('an age we could not compute is drawn as nothing, not 0m', (
    tester,
  ) async {
    await tester.pumpWidget(host(card(age: null)));
    expect(find.text('0m'), findsNothing);
    expect(find.text('now'), findsNothing);
  });
}
