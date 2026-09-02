import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/cli_detection/domain/session_stats.dart';
import 'package:karmashala/src/features/sessions/application/session_stats_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/session_stats_dialog.dart';

import '../../support/window_matrix.dart';

/// The stats dialog in each of its states.
///
/// Every state has to hold at the minimum window with Windows' largest text
/// step, because this is a dialog that opens *over* a session in progress and a
/// clipped row or an unreachable button lands at the worst moment.
void main() {
  const claude = SessionStats(
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

  final codex = SessionStats(
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

  testWidgets('it shows the counts and says where they came from', (
    tester,
  ) async {
    await open(tester, SessionStatsView.computed(claude, 'Claude Code'));

    expect(find.textContaining('Computed from Claude Code'), findsOneWidget);
    expect(find.text('213'), findsOneWidget);
    expect(find.text('3,229'), findsOneWidget);
    expect(find.text('44,952,107'), findsOneWidget);
    // The four buckets added up, with no money anywhere near it.
    expect(find.text('46,343,099'), findsOneWidget);
    expect(find.textContaining(r'$'), findsNothing);
    expect(find.textContaining('cost'), findsOneWidget);
    expect(
      (tester.widget(find.textContaining('cost')) as Text).data,
      contains('no cost estimate'),
    );
  });

  testWidgets('a field the store did not record says so, not zero', (
    tester,
  ) async {
    await open(
      tester,
      SessionStatsView.computed(claude, 'Claude Code'),
    );

    // Claude Code writes no context window and no reasoning split, and this
    // fixture carries no timestamps.
    expect(find.text('Context window'), findsNothing);
    expect(find.text('of which reasoning'), findsNothing);
    expect(find.text(kStatNotRecorded), findsNWidgets(3));
  });

  testWidgets('Codex\'s extra fields appear only when it filled them', (
    tester,
  ) async {
    await open(tester, SessionStatsView.computed(codex, 'Codex'));

    expect(find.text('Context window'), findsOneWidget);
    expect(find.text('258,400'), findsOneWidget);
    expect(find.text('of which reasoning'), findsOneWidget);
    expect(find.text('29,603'), findsOneWidget);
    expect(find.text('2h 11m'), findsOneWidget);
    expect(find.text(kStatNotRecorded), findsNothing);
  });

  testWidgets('an agent with nothing to count explains itself', (tester) async {
    await open(
      tester,
      const SessionStatsView.unavailable(
        SessionStatsUnavailable.agentRecordsNoCounts,
        'Antigravity',
      ),
    );

    expect(find.text('Nothing to count'), findsOneWidget);
    expect(
      find.textContaining('Antigravity records no counts'),
      findsOneWidget,
    );
    // No table of zeros beside the apology.
    expect(find.text('Turns'), findsNothing);
    expect(find.text('0'), findsNothing);
  });

  testWidgets('a session that has not spoken yet says that', (tester) async {
    await open(
      tester,
      const SessionStatsView.unavailable(
        SessionStatsUnavailable.transcriptNotFound,
        'Codex',
      ),
    );

    expect(find.textContaining('has not written a file'), findsOneWidget);
    expect(find.text('Turns'), findsNothing);
  });

  group('the window matrix', () {
    testWidgets('with a full table of seven-figure counts', (tester) async {
      await expectSurvivesWindowMatrix(
        tester,
        build: () => app(SessionStatsView.computed(codex, 'Codex')),
        warmUp: (tester) async => tester.tap(find.text('open')),
        because: 'this opens over a session in progress, at whatever size the '
            'window happens to be',
      );
    });

    testWidgets('and with a paragraph instead of a table', (tester) async {
      await expectSurvivesWindowMatrix(
        tester,
        build: () => app(
          const SessionStatsView.unavailable(
            SessionStatsUnavailable.agentRecordsNoCounts,
            'Antigravity',
          ),
        ),
        warmUp: (tester) async => tester.tap(find.text('open')),
        because: 'the explanation is the longest text this dialog ever holds',
      );
    });
  });
}
