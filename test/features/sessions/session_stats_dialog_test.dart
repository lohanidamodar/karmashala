import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala/src/features/sessions/application/session_stats_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/session_stats_dialog.dart';
import 'package:karmashala/src/features/sessions/presentation/session_stats_sections.dart';
import 'package:karmashala_ui/charts.dart';

import '../../support/window_matrix.dart';

/// The stats dialog in each of its states.
///
/// Two sections from two different books, in one scroll. Every test here is
/// really about the same rule: a number must never appear without saying where
/// it came from, and a field nobody recorded must never appear as a zero.
void main() {
  /// Claude Code: cache-heavy, two models, named tools, output per turn, and
  /// no context window — it does not write one.
  final claudeSession = SessionStats(
    source: SessionStatsSource.localStore,
    turns: 213,
    replies: 3294,
    toolCalls: 3229,
    tokens: const TokenTally(
      input: 5332,
      output: 1199,
      cacheCreated: 1384461,
      cacheRead: 44952107,
    ),
    toolCallsByName: const {
      'Read': 1400,
      'Bash': 900,
      'Edit': 500,
      'Grep': 200,
      'Write': 100,
      'Glob': 80,
      'TodoWrite': 40,
      'WebFetch': 9,
    },
    tokensByModel: const {
      'claude-opus-4-1': TokenTally(
        input: 5000,
        output: 1000,
        cacheCreated: 1300000,
        cacheRead: 44000000,
      ),
      'claude-haiku-4-5': TokenTally(
        input: 332,
        output: 199,
        cacheCreated: 84461,
        cacheRead: 952107,
      ),
    },
    lastPromptTokens: 182000,
    outputTokensPerTurn: const [120, 4000, 12400, 800],
    firstActivityAt: DateTime.utc(2026, 8, 5, 15, 23),
    lastActivityAt: DateTime.utc(2026, 8, 5, 17, 34),
  );

  /// Codex: one running total, a context window, reasoning broken out.
  final codexSession = SessionStats(
    source: SessionStatsSource.localStore,
    turns: 18,
    replies: 50,
    toolCalls: 273,
    tokens: const TokenTally(
      input: 1117718,
      output: 109046,
      cacheRead: 40384768,
      reasoning: 29603,
    ),
    contextWindow: 258400,
    lastPromptTokens: 232560,
    toolCallsByName: const {'shell': 260, 'apply_patch': 10},
    firstActivityAt: DateTime.utc(2026, 8, 5, 15, 23),
    lastActivityAt: DateTime.utc(2026, 8, 5, 17, 34),
  );

  /// A store that recorded almost nothing.
  const partialSession = SessionStats(
    source: SessionStatsSource.localStore,
    turns: 2,
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
    note:
        'Claude Code counts whole messages here, its own and its tools’ '
        'replies together — not the turns and replies counted above.',
  );

  final codexLifetime = LifetimeStats(
    source: LifetimeStatsSource.agentIndex,
    sessions: 61,
    firstActivityAt: DateTime.utc(2025, 9, 17, 11, 8),
    lastActivityAt: DateTime.utc(2026, 8, 30, 16, 12),
    note:
        'Codex records one running total per thread, and a subagent thread '
        'can replay its parent’s history into its own file — so adding '
        'them up can inflate the figure badly. The thread count is safe; the '
        'token total is not, so it is not shown.',
  );

  Widget app(SessionStatsView view) => ProviderScope(
    overrides: [
      sessionStatsProvider('s1').overrideWith((ref) => view),
      agentSessionStatusProvider('s1').overrideWith(
        (ref) => Stream.value(
          AgentStatusReport(
            agentId: 'claude-code',
            sessionId: 'ext',
            status: AgentActivityStatus.idle,
            observedAt: DateTime.utc(2026, 9, 16),
            source: AgentStatusSource.stateFile,
          ),
        ),
      ),
    ],
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
    tester.view.physicalSize = const Size(1440, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(view));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// The first tile so labelled: this session's comes before all time's.
  String tileLabel(WidgetTester tester, String label) {
    final tile = tester.widget<StatTile>(
      find.byWidgetPredicate((w) => w is StatTile && w.label == label).first,
    );
    return [tile.value ?? tile.unrecorded, ?tile.caption].join(' | ');
  }

  Finder text(String pattern) =>
      find.textContaining(pattern, findRichText: true);

  group('the header', () {
    testWidgets('names the session, its status, agent and model', (
      tester,
    ) async {
      await open(
        tester,
        SessionStatsView.computed(
          claudeSession,
          'Claude Code',
          lifetime: claudeLifetime,
          sessionTitle: 'Redesign the stats dialog',
        ),
      );

      expect(find.text('Session stats'), findsOneWidget);
      expect(find.text('Redesign the stats dialog'), findsOneWidget);
      expect(find.text('Idle'), findsOneWidget);
      expect(find.text('Claude Code'), findsOneWidget);
      expect(find.text('claude-opus-4-1 +1 more'), findsOneWidget);
      expect(find.textContaining('Last active'), findsOneWidget);
    });
  });

  group('this session, Claude Code', () {
    testWidgets('headline tiles: compact figures, exact ones beneath', (
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
        find.textContaining('Computed from Claude Code’s own record'),
        findsOneWidget,
      );
      expect(tileLabel(tester, 'Total tokens'), '46.3M | 46,343,099');
      expect(tileLabel(tester, 'Turns'), '213 | 3,294 replies');
      expect(tileLabel(tester, 'Tool calls'), '3,229');
      expect(tileLabel(tester, 'Elapsed'), '2h 11m | first to last record');
    });

    testWidgets('tokens split by kind, with the cache share as a meter', (
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

      final bar = tester.widget<SegmentedBar>(find.byType(SegmentedBar).first);
      expect(
        [for (final s in bar.segments) s.value],
        [5332, 1199, 1384461, 44952107],
      );
      expect(text('Cache read  45M  97%'), findsOneWidget);
      expect(text('Input  5.3k  <1%'), findsOneWidget);
      expect(text('Read from cache'), findsOneWidget);
      // No reasoning split: Claude Code folds thinking into output.
      expect(text('was reasoning'), findsNothing);
    });

    testWidgets('models, tools and turns each get a chart', (tester) async {
      await open(
        tester,
        SessionStatsView.computed(
          claudeSession,
          'Claude Code',
          lifetime: claudeLifetime,
        ),
      );

      expect(find.text('By model'), findsOneWidget);
      expect(find.text('claude-opus-4-1'), findsOneWidget);
      expect(find.text('claude-haiku-4-5'), findsOneWidget);
      expect(find.text('Tool calls by name'), findsOneWidget);
      expect(find.text('Read'), findsOneWidget);
      expect(find.text('WebFetch'), findsNothing, reason: 'past the top six');
      expect(find.text('2 more tools, 49 calls.'), findsOneWidget);
      expect(find.text('Output per turn'), findsOneWidget);
      expect(find.byType(Sparkline), findsOneWidget);
      expect(text('Peak 12.4k at turn 3 of 4'), findsOneWidget);
    });

    testWidgets('a window it never wrote is said, not drawn', (tester) async {
      await open(
        tester,
        SessionStatsView.computed(
          claudeSession,
          'Claude Code',
          lifetime: claudeLifetime,
        ),
      );

      expect(find.text('Context'), findsOneWidget);
      expect(
        text(
          'The newest request sent 182k tokens. The context window size is '
          'not recorded by Claude Code.',
        ),
        findsOneWidget,
      );
      expect(find.text('Newest request'), findsNothing);
    });
  });

  group('this session, Codex', () {
    testWidgets('a context meter, reasoning, and no model or turn charts', (
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

      expect(find.text('Newest request'), findsOneWidget);
      expect(find.text('233k of 258k · 90%'), findsOneWidget);
      expect(text('Of the output, 29.6k was reasoning (27%).'), findsOneWidget);
      expect(
        text('Cache write  not recorded'),
        findsOneWidget,
        reason: 'Codex did not write the bucket, so it is not a zero',
      );
      expect(find.text('By model'), findsNothing);
      expect(find.text('Output per turn'), findsNothing);
      expect(find.text('shell'), findsOneWidget);
      expect(text('3 calls with no tool name recorded.'), findsOneWidget);
    });
  });

  group('what was not recorded', () {
    testWidgets('reads as words, never as a zero', (tester) async {
      await open(
        tester,
        SessionStatsView.computed(
          partialSession,
          'Claude Code',
          lifetime: claudeLifetime,
        ),
      );

      expect(tileLabel(tester, 'Total tokens'), kStatNotRecorded);
      expect(tileLabel(tester, 'Tool calls'), kStatNotRecorded);
      expect(
        tileLabel(tester, 'Elapsed'),
        'not recorded | first to last record',
      );
      expect(tileLabel(tester, 'Turns'), '2');
      expect(text('Token counts are not recorded.'), findsOneWidget);
      expect(
        text('First record not recorded · last not recorded'),
        findsOneWidget,
      );
      expect(
        find.byType(SegmentedBar),
        findsOneWidget,
        reason: 'lifetime only',
      );
      expect(find.text('Context'), findsNothing);
      expect(find.text('Tool calls by name'), findsNothing);
      expect(find.text('0'), findsNothing);
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
      expect(
        find.textContaining(RegExp(r'2026-02-24 \(\d+ days ago\)')),
        findsOneWidget,
      );
      expect(find.textContaining('can be older'), findsOneWidget);
      expect(tileLabel(tester, 'Sessions'), '1');
      expect(tileLabel(tester, 'Messages'), '1,297');
      expect(
        find.byWidgetPredicate(
          (w) => w is StatTile && w.caption == '3,775' && w.value == '3.8k',
        ),
        findsOneWidget,
      );
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
      expect(tileLabel(tester, 'Threads'), '61');
      expect(find.text('Sessions'), findsNothing);
      expect(find.text('Messages'), findsNothing);
      expect(find.textContaining('replay'), findsOneWidget);
      // The total is not invented, and no bar is drawn from buckets it never had.
      final totals = find.byWidgetPredicate(
        (w) => w is StatTile && w.label == 'Total tokens',
      );
      expect(totals, findsNWidgets(2));
      expect(tester.widget<StatTile>(totals.last).value, isNull);
      expect(find.byType(SegmentedBar), findsOneWidget, reason: 'session only');
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
      expect(tileLabel(tester, 'Messages'), '1,297');
      expect(find.textContaining('2026-02-24'), findsOneWidget);
    });
  });

  group('states', () {
    testWidgets('loading shows the spinner, and says what it is doing', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sessionStatsProvider(
              's1',
            ).overrideWith((ref) => Completer<SessionStatsView>().future),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => SessionStatsDialog.show(context, 's1'),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Reading the store…'), findsOneWidget);
      expect(find.byType(StatTile), findsNothing);
    });

    testWidgets('a store that cannot be read says so', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sessionStatsProvider(
              's1',
            ).overrideWith((ref) => Future.error(StateError('locked'))),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => SessionStatsDialog.show(context, 's1'),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Could not be read'), findsOneWidget);
      expect(
        find.textContaining('The store could not be read'),
        findsOneWidget,
      );
    });
  });

  testWidgets('every chart names itself to a screen reader', (tester) async {
    final semantics = tester.ensureSemantics();
    await open(
      tester,
      SessionStatsView.computed(codexSession, 'Codex', lifetime: codexLifetime),
    );
    expect(
      find.bySemanticsLabel(
        RegExp(
          r'^Tokens by kind: input 1\.1M \(3%\), output 109k \(<1%\), '
          r'cache write not recorded, cache read 40\.4M \(97%\)$',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp('^Read from cache: 97% of the tokens sent')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        RegExp(
          '^Context: the newest request sent 233k of '
          '258k tokens of the window, 90%',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Total tokens, 41.6M, 41,611,532'),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('and the turn chart says its peak', (tester) async {
    final semantics = tester.ensureSemantics();
    await open(
      tester,
      SessionStatsView.computed(
        claudeSession,
        'Claude Code',
        lifetime: claudeLifetime,
      ),
    );
    expect(
      find.bySemanticsLabel(RegExp('^Output tokens per turn. Peak 12.4k')),
      findsOneWidget,
    );
    semantics.dispose();
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
    for (final (name, view) in [
      (
        'Claude Code, every chart it can draw',
        SessionStatsView.computed(
          claudeSession,
          'Claude Code',
          lifetime: claudeLifetime,
          sessionTitle:
              'A session title long enough to wrap at the smallest '
              'window the app supports, and then some more',
        ),
      ),
      (
        'Codex, with its context meter and seven-figure counts',
        SessionStatsView.computed(
          codexSession,
          'Codex',
          lifetime: codexLifetime,
        ),
      ),
      (
        'a store that recorded almost nothing',
        SessionStatsView.computed(partialSession, 'Claude Code'),
      ),
    ]) {
      testWidgets('with $name', (tester) async {
        await expectSurvivesWindowMatrix(
          tester,
          build: () => app(view),
          warmUp: (tester) async => tester.tap(find.text('open')),
          because:
              'it opens over a session in progress at whatever size the '
              'window happens to be',
        );
      });
    }

    testWidgets('and with two notices instead of two sections', (tester) async {
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

  group('the numbers behind the charts', () {
    test('cache share needs both input and cache read', () {
      expect(
        cacheReadShare(
          const TokenTally(input: 10, cacheCreated: 10, cacheRead: 80),
        ),
        0.8,
      );
      expect(cacheReadShare(const TokenTally(input: 10)), isNull);
      expect(cacheReadShare(const TokenTally(cacheRead: 10)), isNull);
      expect(cacheReadShare(const TokenTally(input: 0, cacheRead: 0)), isNull);
    });

    test('context fill needs both the prompt and the window', () {
      expect(
        contextFill(
          const SessionStats(
            source: SessionStatsSource.localStore,
            lastPromptTokens: 50,
            contextWindow: 200,
          ),
        ),
        0.25,
      );
      expect(
        contextFill(
          const SessionStats(
            source: SessionStatsSource.localStore,
            lastPromptTokens: 50,
          ),
        ),
        isNull,
      );
    });

    test('tools rank by count, then name, with the rest counted', () {
      final ranked = rankToolCalls(
        const {'b': 2, 'a': 2, 'c': 9, 'd': 1},
        20,
        limit: 2,
      );
      expect(ranked.top, [('c', 9), ('a', 2)]);
      expect(ranked.otherTools, 2);
      expect(ranked.otherCalls, 3);
      expect(ranked.unnamed, 6);
      expect(rankToolCalls(const {'a': 1}, null).unnamed, 0);
    });

    test('the peak turn is the first of equals, counted from one', () {
      expect(peakTurn(const [1, 5, 5]), (turn: 2, tokens: 5));
      expect(peakTurn(const []), isNull);
    });

    test('the spoken split names what was not recorded', () {
      expect(
        tokenSplitSummary(const TokenTally(input: 1, output: 3)),
        'Tokens by kind: input 1 (25%), output 3 (75%), '
        'cache write not recorded, cache read not recorded',
      );
    });
  });
}
