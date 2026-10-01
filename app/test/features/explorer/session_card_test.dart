import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/rows.dart';
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

  /// Under a pointer by default: the desktop Explorer's one-line row. [touch]
  /// is the three-line card a thumb gets (spec §2.4 keeps it there).
  Widget host(Widget child, {double width = 320, bool touch = false}) =>
      MaterialApp(
        theme: AppTheme.light().copyWith(
          platform: touch ? TargetPlatform.android : TargetPlatform.windows,
        ),
        builder: (context, inner) => UiDensity.wrap(context, inner!),
        home: Scaffold(
          body: SizedBox(width: width, child: child),
        ),
      );

  /// The title's hover under a pointer: what the one line no longer draws.
  Finder hoverSaying(String words) => find.byWidgetPredicate(
    (widget) => widget is Tooltip && (widget.message ?? '').contains(words),
  );

  SessionCard card({
    String title = 'Benchmark arcade games',
    String? branch = 'monocode/main',
    String? whereabouts,
    String? age = '22m',
    SessionDiffStat? stat,
    bool worktree = false,
    bool selected = false,
    bool unread = false,
  }) => SessionCard(
    depth: 1,
    selected: selected,
    unread: unread,
    agentIcon: AppIcons.playCircle,
    agentLabel: 'Claude Code  ·  running',
    title: title,
    age: age,
    branch: branch,
    whereabouts: whereabouts,
    stat: stat,
    worktree: worktree,
    onTap: () {},
    menuItemsBuilder: () => const [],
    onMenu: (_) {},
  );

  testWidgets('under a pointer, one line: status, title and age; who and '
      'where are the title\'s hover, in the same words', (tester) async {
    // Spec §2.4: a session under a project is one 28px line.
    await tester.pumpWidget(
      host(
        card(
          whereabouts: 'opened in an external terminal',
          stat: const SessionDiffStat(branch: 'feature/x', changedFiles: 6),
        ),
      ),
    );

    const meta =
        'Claude Code  ·  running  ·  monocode/main  ·  '
        'opened in an external terminal';
    expect(find.text(meta), findsNothing);
    expect(find.text('6 changed'), findsNothing);
    expect(find.text('22m'), findsOneWidget);
    expect(find.text('Benchmark arcade games'), findsOneWidget);
    final title = tester.getCenter(find.text('Benchmark arcade games')).dy;
    expect(tester.getCenter(find.text('22m')).dy, title);

    expect(hoverSaying(meta), findsWidgets);
    expect(hoverSaying('6 changed'), findsWidgets);
  });

  testWidgets('under a thumb, three lines: who and when, what, then where '
      'and what it produced', (tester) async {
    // Design direction S2: the work leads, the agent is metadata.
    await tester.pumpWidget(
      host(
        card(
          whereabouts: 'opened in an external terminal',
          stat: const SessionDiffStat(branch: 'feature/x', changedFiles: 6),
        ),
        touch: true,
      ),
    );

    const where = 'monocode/main  ·  opened in an external terminal';
    expect(find.text('Claude Code  ·  running'), findsOneWidget);
    expect(find.text(where), findsOneWidget);
    expect(find.text('22m'), findsOneWidget);
    expect(find.text('6 changed'), findsOneWidget);

    final title = tester.getCenter(find.text('Benchmark arcade games')).dy;
    expect(tester.getCenter(find.text('22m')).dy, lessThan(title));
    expect(tester.getTopLeft(find.text(where)).dy, greaterThan(title));
    expect(tester.getCenter(find.text('6 changed')).dy, greaterThan(title));
  });

  testWidgets('the age and the diff stat sit on the right edge', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(card(stat: const SessionDiffStat(changedFiles: 2)), touch: true),
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
        touch: true,
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
        touch: true,
      ),
    );
    expect(find.text('+949'), findsOneWidget);
    expect(find.text('−10'), findsOneWidget);
    expect(find.text('6 changed'), findsNothing);
  });

  testWidgets('commits ahead show beside the change count', (tester) async {
    await tester.pumpWidget(
      host(
        card(stat: const SessionDiffStat(changedFiles: 1, commitsAhead: 3)),
        touch: true,
      ),
    );
    expect(find.text('↑3'), findsOneWidget);
    expect(find.text('1 changed'), findsOneWidget);
  });

  testWidgets('a third line is drawn only for a sub-path', (tester) async {
    await tester.pumpWidget(host(card(branch: null), touch: true));
    final twoLines = tester.getSize(find.byType(SessionCard)).height;

    await tester.pumpWidget(
      host(
        SessionCard(
          depth: 1,
          selected: false,
          agentIcon: AppIcons.playCircle,
          agentLabel: 'Claude Code',
          title: 'Benchmark arcade games',
          subPath: 'packages/app',
          onTap: () {},
          menuItemsBuilder: () => const [],
          onMenu: (_) {},
        ),
        touch: true,
      ),
    );
    expect(find.text('packages/app'), findsOneWidget);
    expect(
      tester.getSize(find.byType(SessionCard)).height,
      greaterThan(twoLines),
    );
  });

  testWidgets('the worktree glyph appears only for a worktree session', (
    tester,
  ) async {
    await tester.pumpWidget(host(card(), touch: true));
    expect(find.byIcon(AppIcons.treeStructure), findsNothing);

    await tester.pumpWidget(host(card(worktree: true), touch: true));
    expect(find.byIcon(AppIcons.treeStructure), findsOneWidget);

    // Under a pointer the one line has no room for it; the hover says it.
    await tester.pumpWidget(host(card(worktree: true)));
    expect(hoverSaying('Runs in its own worktree'), findsWidgets);
  });

  testWidgets('a finished turn nobody has seen is a filled dot, in the unread '
      'colour, where the status glyph was', (tester) async {
    await tester.pumpWidget(host(card()));
    final status = tester.getCenter(find.byIcon(AppIcons.playCircle));
    final titleLeft = tester.getTopLeft(find.text('Benchmark arcade games'));

    await tester.pumpWidget(host(card(unread: true)));
    expect(find.byIcon(AppIcons.circle), findsNothing, reason: 'hollow');
    final dot = find.byIcon(AppIcons.circleFill);
    expect(dot, findsOneWidget);
    final context = tester.element(dot);
    expect(tester.widget<Icon>(dot).color, SemanticColors.of(context).unread);
    expect(tester.widget<Icon>(dot).size, UiDensity.of(context).iconSmall);
    expect(find.byTooltip('Finished — not seen yet'), findsOneWidget);

    // One slot: the dot stands where the glyph stood and the title stays put.
    expect(tester.getCenter(dot), status);
    expect(tester.getTopLeft(find.text('Benchmark arcade games')), titleLeft);
  });

  testWidgets('an age we could not compute is drawn as nothing, not 0m', (
    tester,
  ) async {
    await tester.pumpWidget(host(card(age: null)));
    expect(find.text('0m'), findsNothing);
    expect(find.text('now'), findsNothing);
  });
}
