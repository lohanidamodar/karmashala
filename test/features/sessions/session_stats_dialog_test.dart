import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala/src/features/sessions/application/session_stats_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/session_stats_dialog.dart';

import '../../support/window_matrix.dart';

/// The stats dialog in each of its states.
///
/// Two sections from two different books, in one scroll. Every test here is
/// really about the same rule: a number must never appear without saying where
/// it came from, and a field nobody recorded must never appear as a zero.
void main() {
  const claudeSession = SessionStats(
    source: SessionStatsSource.localStore,
    turns: 213,
    replies: 3294,
    toolCalls: 3229,
    tokens: TokenTally(
      input: 5332,
      output: 1199,
      cacheCreated: 1384461,
      cacheRead: 44952107,
    ),
  );

  final codexSession = SessionStats(
    source: SessionStatsSource.localStore,
    turns: 18,
    replies: 50,
    toolCalls: 273,
    tokens: const TokenTally(
      input: 1117718,
      output: 109046,
      cacheCreated: 0,
      cacheRead: 40384768,
      reasoning: 29603,
    ),
    contextWindow: 258400,
    firstActivityAt: DateTime.utc(2026, 8, 5, 15, 23),
    lastActivityAt: DateTime.utc(2026, 8, 5, 17, 34),
  );

  /// Claude Code's real cache, six months stale and claiming one session.
  final claudeLifetime = LifetimeStats(
    source: LifetimeStatsSource.agentCache,
    sessions: 1,
    messages: 1297,
    tokens: const TokenTally(
      input: 777,
      output: 888,
      cacheCreated: 999,
      cacheRead: 1111,
    ),
    totalTokens: 3775,
    computedAt: DateTime.utc(2026, 2, 24),
    firstActivityAt: DateTime.utc(2026, 2, 1, 9, 41),
    note: 'Claude Code counts whole messages here, its own and its tools\u2019 '
        'replies together — not the turns and replies counted above.',
  );

  final codexLifetime = LifetimeStats(
    source: LifetimeStatsSource.agentIndex,
    sessions: 61,
    firstActivityAt: DateTime.utc(2025, 9, 17, 11, 8),
    lastActivityAt: DateTime.utc(2026, 8, 30, 16, 12),
    note: 'Codex records one running total per thread, and a subagent thread '
        'can replay its parent\u2019s history into its own file — so adding '
        'them up can inflate the figure badly. The thread count is safe; the '
        'token total is not, so it is not shown.',
  );

  Widget app(SessionStatsView view) => ProviderScope(
    overrides: [sessionStatsProvider('s1').overrideWith((ref) => view)],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => SessionStatsDialog.show(context, 's1'),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );

  Future<void> open(WidgetTester tester, SessionStatsView view) async {
    await tester.pumpWidget(app(view));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('this session', () {
    testWidgets('it shows the counts and says where they came from', (
      tester,
    ) async {
      await open(
        tester,
        SessionStatsView.computed(
          claudeSession,
          'Claude Code',
          lifetime: claudeLifetime,
        ),
      );

      expect(find.text('This session'.toUpperCase()), findsOneWidget);
      expect(
        find.textContaining('Computed from Claude Code\u2019s own record'),
        findsOneWidget,
      );
      expect(find.text('213'), findsOneWidget);
      expect(find.text('3,229'), findsOneWidget);
      expect(find.text('44,952,107'), findsOneWidget);
      expect(find.text('46,343,099'), findsOneWidget);
    });

    testWidgets('a field the store did not record says so, not zero', (
      tester,
    ) async {
      await open(
        tester,
        SessionStatsView.computed(
          claudeSession,
          'Claude Code',
          lifetime: claudeLifetime,
        ),
      );

      // Claude Code writes no context window and no reasoning split; this
      // fixture carries no timestamps, and its cache records no last activity.
      expect(find.text('Context window'), findsNothing);
      expect(find.text('of which reasoning'), findsNothing);
      expect(find.text(kStatNotRecorded), findsNWidgets(4));
      expect(find.text('0'), findsNothing);
    });

    testWidgets('Codex\'s extra fields appear only when it filled them', (
      tester,
    ) async {
      await open(
        tester,
        SessionStatsView.computed(
          codexSession,
          'Codex',
          lifetime: codexLifetime,
        ),
      );

      expect(find.text('Context window'), findsOneWidget);
      expect(find.text('258,400'), findsOneWidget);
      expect(find.text('of which reasoning'), findsOneWidget);
      expect(find.text('29,603'), findsOneWidget);
      expect(find.text('2h 11m'), findsOneWidget);
    });
  });

  group('all time', () {
    testWidgets('a cache says when it was written and that it can lag', (
      tester,
    ) async {
      await open(
        tester,
        SessionStatsView.computed(
          claudeSession,
          'Claude Code',
          lifetime: claudeLifetime,
        ),
      );

      expect(find.text('All time'.toUpperCase()), findsOneWidget);
      expect(find.textContaining('2026-02-24'), findsOneWidget);
      expect(find.textContaining('days ago'), findsOneWidget);
      expect(find.textContaining('can be older'), findsOneWidget);
      expect(find.text('Sessions'), findsOneWidget);
      expect(find.text('1,297'), findsOneWidget);
      expect(find.text('3,775'), findsOneWidget);
      // Its unit caveat is on screen, not only in a comment.
      expect(find.textContaining('counts whole messages'), findsOneWidget);
    });

    testWidgets('an index says it is current, and withholds the total', (
      tester,
    ) async {
      await open(
        tester,
        SessionStatsView.computed(
          codexSession,
          'Codex',
          lifetime: codexLifetime,
        ),
      );

      expect(find.textContaining('kept current as it runs'), findsOneWidget);
      expect(find.text('Threads'), findsOneWidget);
      expect(find.text('Sessions'), findsNothing);
      expect(find.text('61'), findsOneWidget);
      expect(find.textContaining('replay'), findsOneWidget);
      // Four buckets and the total, none of them invented.
      expect(find.text(kStatNotRecorded), findsNWidgets(5));
    });

    testWidgets('an agent with no books of its own says that', (tester) async {
      await open(
        tester,
        SessionStatsView.computed(
          claudeSession,
          'Antigravity',
          lifetimeUnavailable: LifetimeStatsUnavailable.agentKeepsNoAggregate,
        ),
      );

      expect(
        find.textContaining('keeps no lifetime totals of its own'),
        findsOneWidget,
      );
      expect(find.textContaining('does not add sessions together'),
          findsOneWidget);
      expect(find.text('Threads'), findsNothing);
    });

    testWidgets('books that exist but have never been written here', (
      tester,
    ) async {
      await open(
        tester,
        SessionStatsView.computed(
          claudeSession,
          'Claude Code',
          lifetimeUnavailable: LifetimeStatsUnavailable.sourceNotFound,
        ),
      );

      expect(
        find.textContaining('none could be read on this machine'),
        findsOneWidget,
      );
    });

    testWidgets('it survives a session that has nothing to show', (
      tester,
    ) async {
      // The independence claim: one section going quiet must not take the
      // other with it.
      await open(
        tester,
        SessionStatsView.unavailable(
          SessionStatsUnavailable.transcriptNotFound,
          'Claude Code',
          lifetime: claudeLifetime,
        ),
      );

      expect(find.textContaining('has not written a file'), findsOneWidget);
      expect(find.text('Turns'), findsNothing);
      expect(find.text('1,297'), findsOneWidget);
      expect(find.textContaining('2026-02-24'), findsOneWidget);
    });
  });

  testWidgets('no money anywhere, and it does not claim to be a bill', (
    tester,
  ) async {
    await open(
      tester,
      SessionStatsView.computed(
        claudeSession,
        'Claude Code',
        lifetime: claudeLifetime,
      ),
    );

    expect(find.textContaining(r'$'), findsNothing);
    expect(find.textContaining('no cost estimate'), findsOneWidget);
    expect(find.textContaining('not a bill'), findsOneWidget);
  });

  group('the window matrix', () {
    testWidgets('with both sections full of seven-figure counts', (
      tester,
    ) async {
      await expectSurvivesWindowMatrix(
        tester,
        build: () => app(
          SessionStatsView.computed(
            codexSession,
            'Codex',
            lifetime: codexLifetime,
          ),
        ),
        warmUp: (tester) async => tester.tap(find.text('open')),
        because: 'this is the tallest the dialog gets, and it opens over a '
            'session in progress at whatever size the window happens to be',
      );
    });

    testWidgets('and with two paragraphs instead of two tables', (tester) async {
      await expectSurvivesWindowMatrix(
        tester,
        build: () => app(
          const SessionStatsView.unavailable(
            SessionStatsUnavailable.agentRecordsNoCounts,
            'Antigravity',
            lifetimeUnavailable: LifetimeStatsUnavailable.agentKeepsNoAggregate,
          ),
        ),
        warmUp: (tester) async => tester.tap(find.text('open')),
        because: 'the two explanations are the longest text this dialog holds',
      );
    });
  });
}
