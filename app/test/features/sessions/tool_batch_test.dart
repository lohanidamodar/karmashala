import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/stream.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala/src/features/sessions/presentation/tool_activity_row.dart';
import 'package:karmashala/src/features/sessions/presentation/tool_run.dart';

/// **A run of tool calls reads as one line.** Between two of the model's
/// sentences, twenty file reads are one step. What must never disappear into
/// the fold is the row somebody is looking for: a failure, a call waiting on
/// the user, a call the model reasoned its way to.
void main() {
  ChatMessage tool(
    String name, {
    String? subject,
    String? output = 'done',
    bool isError = false,
    bool pending = false,
    String? thinking,
  }) => ChatMessage(
    role: 'tool',
    text: name,
    thinking: thinking,
    pending: pending,
    tool: ToolActivity(
      name: name,
      subject: subject,
      output: output,
      isError: isError,
    ),
  );

  ChatMessage said(String text) => ChatMessage(role: 'agent', text: text);

  group('grouping', () {
    test('a run of three calls is one row; two stay flat', () {
      final rows = transcriptRows([
        said('working'),
        tool('Read'),
        tool('Read'),
        tool('Bash'),
        said('done'),
        tool('Read'),
        tool('Read'),
      ]);

      expect(rows.map((r) => (r.from, r.to)), [
        (0, 1),
        (1, 4),
        (4, 5),
        (5, 6),
        (6, 7),
      ]);
      expect(rows[1].isBatch, isTrue);
      expect(rows[1].live, isFalse);
    });

    test('anything that is not a tool call ends a run', () {
      final rows = transcriptRows([
        tool('Read'),
        tool('Read'),
        const ChatMessage(role: 'tool', text: 'Session ended.'),
        tool('Read'),
        const ChatMessage(role: 'error', text: 'boom'),
        tool('Read'),
        const ChatMessage(role: kCompactionNoticeRole, text: 'compacted'),
        tool('Read'),
        const ChatMessage(role: 'user', text: 'hi'),
      ]);

      expect(rows.every((r) => !r.isBatch), isTrue);
    });

    test('a failure stays in its run but is pinned, not hidden', () {
      final rows = transcriptRows([
        tool('Read'),
        tool('Read'),
        tool('Bash', isError: true),
        tool('Read'),
        tool('Read'),
      ]);

      expect(rows, hasLength(1));
      expect(rows.single.length, 5);
      expect(rows.single.pinned, [2]);
      expect(rows.single.hidden, 4);
    });

    test('the threshold counts the rows a fold hides, not the calls', () {
      // Three calls, but the failure is drawn either way: folding would take
      // two rows off screen, which is not worth a line.
      final three = transcriptRows([
        tool('Read'),
        tool('Read'),
        tool('Bash', isError: true),
      ]);
      expect(three.every((r) => !r.isBatch), isTrue);

      final four = transcriptRows([
        tool('Read'),
        tool('Bash', isError: true),
        tool('Read'),
        tool('Read'),
      ]);
      expect(four.single.isBatch, isTrue);
      expect(four.single.hidden, 3);
    });

    test('a call the model reasoned its way to is pinned', () {
      final rows = transcriptRows([
        tool('Read'),
        tool('Read'),
        tool('Grep', thinking: 'where does this get called'),
        tool('Read'),
      ]);

      expect(rows.single.pinned, [2]);
    });

    test('an unanswered call in a settled run is pinned', () {
      final rows = transcriptRows([
        tool('Read'),
        tool('Read'),
        tool('Read'),
        tool('Bash', output: null, pending: true),
        said('I stopped'),
      ], turn: TranscriptTurn.working);

      expect(rows.first.live, isFalse);
      expect(rows.first.pinned, [3]);
    });

    test('an empty answer is not a pending call', () {
      final rows = transcriptRows([
        tool('Read', output: null),
        tool('Read', output: null),
        tool('Read', output: null),
      ], turn: TranscriptTurn.idle);

      expect(rows.single.isBatch, isTrue);
      expect(rows.single.pinned, isEmpty);
    });

    test('subagent calls fold with the rest and say what they were', () {
      final run = [
        tool('Task', subject: 'survey the parser'),
        tool('Agent', subject: 'review'),
        tool('Read', subject: 'a.dart'),
      ];
      expect(transcriptRows(run).single.isBatch, isTrue);
      expect(describeToolRun(run), 'Delegated 2 tasks, read 1 file');
    });

    test('an empty transcript has no rows', () {
      expect(transcriptRows(const []), isEmpty);
    });
  });

  group('live', () {
    final run = [
      said('on it'),
      tool('Read'),
      tool('Read'),
      tool('Bash', output: null, pending: true),
    ];

    test('the trailing run of a working turn is live', () {
      final rows = transcriptRows([
        ...run.take(3),
        tool('Read'),
      ], turn: TranscriptTurn.working);
      expect(rows.last.live, isTrue);
      // Between calls nothing is pending, and it is still the same live run.
      expect(rows.last.pinned, isEmpty);
    });

    test('a running call is the live line, not a pinned row', () {
      final rows = transcriptRows(run, turn: TranscriptTurn.working);
      expect(rows.last.live, isTrue);
      expect(rows.last.pinned, isEmpty);
    });

    test('an idle turn has no live run, whatever is pending', () {
      // The unanswered call is pinned, which leaves two to hide: flat.
      final rows = transcriptRows(run, turn: TranscriptTurn.idle);
      expect(rows.any((r) => r.live || r.isBatch), isFalse);
      final longer = transcriptRows([
        tool('Read'),
        ...run.skip(1),
      ], turn: TranscriptTurn.idle);
      expect(longer.single.live, isFalse);
      expect(longer.single.pinned, [3]);
    });

    test('with no status, an unanswered call is the evidence', () {
      expect(transcriptRows(run).last.live, isTrue);
      final answered = [...run.take(3), tool('Bash')];
      expect(transcriptRows(answered).last.live, isFalse);
    });

    test('only the trailing run can be live', () {
      final rows = transcriptRows([
        ...run.skip(1).take(2),
        tool('Read'),
        said('found it'),
      ], turn: TranscriptTurn.working);
      expect(rows.first.isBatch, isTrue);
      expect(rows.first.live, isFalse);
    });

    test('a turn waiting on the user pins what it is waiting on', () {
      final rows = transcriptRows([
        tool('Read'),
        tool('Read'),
        tool('Read'),
        tool('Bash', output: null, pending: true),
      ], turn: TranscriptTurn.awaitingUser);
      expect(rows.single.live, isTrue);
      expect(rows.single.pinned, [3]);
    });

    test('a question to the user is pinned even mid-turn', () {
      final rows = transcriptRows([
        tool('Read'),
        tool('Read'),
        tool('Read'),
        tool('AskUserQuestion', output: null, pending: true),
      ], turn: TranscriptTurn.working);
      expect(rows.single.pinned, [3]);
    });

    test('the status badge maps onto the turn', () {
      AgentStatusReport report(AgentActivityStatus status) => AgentStatusReport(
        agentId: 'claude-code',
        sessionId: 's',
        status: status,
        observedAt: DateTime(2026),
        source: AgentStatusSource.hook,
      );
      expect(
        transcriptTurnFor(report(AgentActivityStatus.working)),
        TranscriptTurn.working,
      );
      expect(
        transcriptTurnFor(report(AgentActivityStatus.awaitingApproval)),
        TranscriptTurn.awaitingUser,
      );
      expect(
        transcriptTurnFor(report(AgentActivityStatus.failed)),
        TranscriptTurn.idle,
      );
      expect(transcriptTurnFor(null), TranscriptTurn.unknown);
    });
  });

  group('what the line says', () {
    test('counts by kind, in first-seen order', () {
      expect(
        describeToolRun([
          tool('Bash', subject: 'ls'),
          tool('Read', subject: 'a.dart'),
          tool('Edit', subject: 'a.dart'),
          tool('Bash', subject: 'flutter test'),
          tool('Read', subject: 'b.dart'),
        ]),
        'Ran 2 commands, read 2 files, edited 1 file',
      );
    });

    test('a file read twice is one file read', () {
      expect(
        describeToolRun([
          tool('Read', subject: 'a.dart'),
          tool('Read', subject: 'a.dart'),
          tool('Read', subject: 'b.dart'),
          tool('Read'),
        ]),
        'Read 3 files',
      );
    });

    test('every CLI\'s vocabulary lands on the same words', () {
      expect(
        describeToolRun([
          tool('exec_command', subject: 'ls'),
          tool('shell', subject: 'pwd'),
          tool('apply_patch'),
          tool('update_plan'),
          tool('mcp__karmashala__list_sessions'),
          tool('grep_search'),
          tool('WebFetch'),
        ]),
        'Ran 2 commands, applied 1 patch, updated the plan, called 1 MCP '
        'tool, ran 1 search, fetched 1 page',
      );
    });

    test('tools it cannot name are still counted', () {
      expect(
        describeToolRun([tool('Frobnicate'), tool('Zap')]),
        'Used 2 tools',
      );
      expect(
        describeToolRun([tool('Bash'), tool('Frobnicate')]),
        'Ran 1 command, used 1 other tool',
      );
    });

    test('failures are counted on the line', () {
      expect(
        describeToolRun([
          tool('Bash', isError: true),
          tool('Bash'),
          tool('Read'),
        ]),
        'Ran 2 commands, read 1 file · 1 failed',
      );
    });
  });

  group('on screen', () {
    Widget view(
      List<ChatMessage> messages, {
      TranscriptTurn turn = TranscriptTurn.unknown,
    }) => MaterialApp(
      home: Scaffold(
        body: ChatTranscriptView(messages: messages, turn: turn),
      ),
    );

    Finder shown(String text) => find.textContaining(text, findRichText: true);

    testWidgets('a settled run is one line until it is opened', (tester) async {
      await tester.pumpWidget(
        view([
          said('working'),
          tool('Read', subject: 'lib/one.dart'),
          tool('Read', subject: 'lib/two.dart'),
          tool('Bash', subject: 'flutter analyze'),
        ]),
      );
      await tester.pumpAndSettle();

      expect(find.text('Read 2 files, ran 1 command'), findsOneWidget);
      expect(shown('flutter analyze'), findsNothing);

      await tester.tap(find.text('Read 2 files, ran 1 command'));
      await tester.pumpAndSettle();
      expect(shown('flutter analyze'), findsWidgets);
      expect(shown('lib/one.dart'), findsWidgets);

      await tester.tap(find.text('Read 2 files, ran 1 command'));
      await tester.pumpAndSettle();
      expect(shown('flutter analyze'), findsNothing);
    });

    testWidgets('a failure is drawn while its run is folded', (tester) async {
      await tester.pumpWidget(
        view([
          tool('Read', subject: 'lib/one.dart'),
          tool('Bash', subject: 'flutter test', isError: true),
          tool('Read', subject: 'lib/two.dart'),
          tool('Read', subject: 'lib/three.dart'),
          said('done'),
        ]),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Read 3 files, ran 1 command · 1 failed'),
        findsOneWidget,
      );
      expect(shown('flutter test'), findsWidgets);
      expect(find.text('FAILED'), findsOneWidget);
      expect(shown('lib/two.dart'), findsNothing);
    });

    testWidgets('what the agent said is never folded', (tester) async {
      await tester.pumpWidget(
        view([
          said('here is the plan'),
          tool('Read'),
          tool('Read'),
          tool('Read'),
          said('and here is what I found'),
        ]),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('here is the plan'), findsOneWidget);
      expect(find.textContaining('and here is what I found'), findsOneWidget);
    });

    testWidgets('a live run is one line naming the newest call, and opening '
        'it does not survive the turn', (tester) async {
      final calls = [
        said('on it'),
        tool('Read', subject: 'lib/one.dart'),
        tool('Read', subject: 'lib/two.dart'),
        tool('Bash', subject: 'flutter test', output: null, pending: true),
      ];
      await tester.pumpWidget(view(calls, turn: TranscriptTurn.working));
      await tester.pumpAndSettle();

      expect(find.text('Working'), findsOneWidget);
      expect(find.text('Bash  flutter test'), findsOneWidget);
      expect(find.text('3 calls so far'), findsOneWidget);
      expect(shown('lib/one.dart'), findsNothing);

      // Opened while live, it stays open as the run grows.
      await tester.tap(find.text('Working'));
      await tester.pumpAndSettle();
      expect(shown('lib/one.dart'), findsWidgets);

      final grown = [
        ...calls.take(3),
        tool('Bash', subject: 'flutter test'),
        tool('Edit', subject: 'lib/two.dart', output: null, pending: true),
      ];
      await tester.pumpWidget(view(grown, turn: TranscriptTurn.working));
      await tester.pumpAndSettle();
      expect(find.text('Edit  lib/two.dart'), findsOneWidget);
      expect(shown('lib/one.dart'), findsWidgets);

      // Settled, it is a different line with its own state: folded.
      final settled = [
        ...grown.take(4),
        tool('Edit', subject: 'lib/two.dart'),
        said('all green'),
      ];
      await tester.pumpWidget(view(settled, turn: TranscriptTurn.idle));
      await tester.pumpAndSettle();
      expect(find.text('Working'), findsNothing);
      expect(
        find.text('Read 2 files, ran 1 command, edited 1 file'),
        findsOneWidget,
      );
      expect(shown('lib/one.dart'), findsNothing);
    });

    testWidgets('the turn ending settles the line even with no new message', (
      tester,
    ) async {
      final calls = [
        tool('Read', subject: 'lib/one.dart'),
        tool('Read', subject: 'lib/two.dart'),
        tool('Read', subject: 'lib/three.dart'),
      ];
      await tester.pumpWidget(view(calls, turn: TranscriptTurn.working));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Working'));
      await tester.pumpAndSettle();
      expect(shown('lib/one.dart'), findsWidgets);

      await tester.pumpWidget(view(calls, turn: TranscriptTurn.idle));
      await tester.pumpAndSettle();
      expect(find.text('Read 3 files'), findsOneWidget);
      expect(shown('lib/one.dart'), findsNothing);
    });

    testWidgets('both lines fit a phone at large text', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      final calls = [
        for (var i = 0; i < 12; i++)
          tool('Read', subject: 'lib/src/features/a/very/long/path/f$i.dart'),
        tool('Bash', subject: 'flutter test --exclude-tags=live-ssh,live-wsl'),
      ];
      for (final turn in [TranscriptTurn.working, TranscriptTurn.idle]) {
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(
              size: Size(390, 844),
              textScaler: TextScaler.linear(2),
            ),
            child: view(calls, turn: turn),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('a turn waiting on the user draws the call it waits on', (
      tester,
    ) async {
      final calls = [
        tool('Read', subject: 'lib/one.dart'),
        tool('Read', subject: 'lib/two.dart'),
        tool('Read', subject: 'lib/three.dart'),
        tool('Bash', subject: 'rm -rf build', output: null, pending: true),
      ];

      // Merely working: the line names the call and no row is drawn.
      await tester.pumpWidget(view(calls, turn: TranscriptTurn.working));
      await tester.pumpAndSettle();
      expect(find.text('Bash  rm -rf build'), findsOneWidget);
      expect(find.byType(ToolActivityBody), findsNothing);

      // Waiting on the user: the row itself is drawn beneath the line.
      await tester.pumpWidget(view(calls, turn: TranscriptTurn.awaitingUser));
      await tester.pumpAndSettle();
      expect(find.text('Working'), findsOneWidget);
      expect(find.byType(ToolActivityBody), findsOneWidget);
      expect(shown('lib/one.dart'), findsNothing);
    });
  });
}
