import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:agent_cli/stream.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/application/turn_forks.dart';
import 'package:karmashala/src/features/sessions/data/sessions_client.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart'
    show forkPreviewMessage;
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/window_matrix.dart';

/// Retry, Edit and resend, Fork from here and Copy turn on each turn: only
/// where the session can do them, disabled with a reason where they wait,
/// and asking before an earlier message is sent again.
void main() {
  final t0 = DateTime.utc(2026, 10, 8, 9);
  DateTime at(int minutes) => t0.add(Duration(minutes: minutes));

  final history = [
    ChatMessage(role: 'user', text: 'Add a test', at: at(0)),
    ChatMessage(
      role: 'tool',
      text: 'Bash(dart test)',
      at: at(1),
      tool: ToolActivity(
        name: 'Bash',
        subject: 'dart test',
        output: 'All tests passed!',
        endedAt: at(1).add(const Duration(milliseconds: 2400)),
      ),
    ),
    ChatMessage(role: 'agent', text: 'Added it.', at: at(2)),
    ChatMessage(role: 'user', text: 'Now the docs', at: at(10)),
    ChatMessage(role: 'agent', text: 'Done.', at: at(11)),
  ];

  Checkpoint checkpoint(
    String id,
    int turn,
    DateTime when, {
    CheckpointReason reason = CheckpointReason.turnStart,
    String? prompt,
  }) => Checkpoint(
    id: id,
    sessionId: 's1',
    repository: const EnvironmentPath(environmentId: 'w', path: r'C:\repo'),
    sequence: turn,
    treeSha: 't$id',
    commitSha: 'c$id',
    parentCommitSha: null,
    headSha: null,
    reason: reason,
    createdAt: when,
    turn: turn,
    prompt: prompt,
  );

  group('fork points', () {
    test('each turn meets its own checkpoint, before and after', () {
      final points = turnForkPoints(transcriptTurnStarts(history), [
        checkpoint('a', 1, at(0).add(const Duration(seconds: 1))),
        checkpoint('b', 1, at(3), reason: CheckpointReason.turn),
        checkpoint('c', 2, at(10)),
        checkpoint('d', 2, at(12), reason: CheckpointReason.turn),
      ]);
      expect(points[0]!.before, const TurnForkTarget.turn(1));
      expect(points[0]!.after, const TurnForkTarget.turn(2));
      expect(points[3]!.before, const TurnForkTarget.turn(2));
      expect(points[3]!.after, const TurnForkTarget.checkpoint('d'));
    });

    test('its prompt beats a nearer time; a turn with none has no entry', () {
      final points = turnForkPoints(transcriptTurnStarts(history), [
        checkpoint('x', 7, at(0), prompt: 'something else'),
        checkpoint('y', 8, at(5), prompt: 'Add a test'),
      ]);
      expect(points[0]!.before, const TurnForkTarget.turn(8));
      expect(points.containsKey(3), isFalse);
      expect(turnForkPoints(transcriptTurnStarts(history), const []), isEmpty);
    });
  });

  group('the fork goes to the server\'s fork-from-checkpoint', () {
    test('a preview first, then the fork, and the new session shown', () async {
      final client = _FakeSessions({
        'preview': true,
        'explanation': 'Forked natively.',
        'conversation': {'note': 'The conversation is carried whole.'},
        'repositories': [
          {'repository': r'C:\repo', 'wouldRestore': true},
          {
            'repository': r'C:\other',
            'wouldRestore': false,
            'reason': 'Another session works there.',
          },
        ],
      });
      final shown = <String>[];
      final forks = TurnForks(client, show: (id) async => shown.add(id));

      final preview = await forks.preview('s1', const TurnForkTarget.turn(2));
      expect(client.asked.single.preview, isTrue);
      expect(client.asked.single.turn, 2);
      expect(preview.repositories.map((r) => r.restores), [true, false]);
      final words = forkPreviewMessage(preview);
      expect(words, contains(r'C:\repo go back'));
      expect(words, contains('Another session works there.'));
      expect(words, contains('carried whole'));

      client.answer = {'sessionId': 'fork-1'};
      await forks.fork('s1', const TurnForkTarget.checkpoint('d'));
      expect(client.asked.last.preview, isFalse);
      expect(client.asked.last.checkpointId, 'd');
      expect(client.asked.last.turn, isNull);
      expect(shown, ['fork-1']);

      client.answer = {'preview': false};
      await expectLater(
        forks.fork('s1', const TurnForkTarget.turn(1)),
        throwsStateError,
      );
    });
  });

  test('Copy turn is the turn as Markdown', () {
    final text = transcriptTurnMarkdown(history, 2);
    expect(
      text,
      '### You\n\nAdd a test\n\n### Agent\n\n'
      '- **Bash** `dart test` (2.4s)\n\nAdded it.',
    );
    expect(transcriptTurnMarkdown(history, 3), startsWith('### You\n\nNow'));
  });

  group('on each turn', () {
    late List<String> retried;
    late List<String> edited;
    late List<TurnForkTarget> forked;

    setUp(() {
      retried = [];
      edited = [];
      forked = [];
    });

    TranscriptTurnActions actions({
      String? busy,
      Map<int, TurnForkPoints> points = const {},
      bool canSend = true,
    }) => TranscriptTurnActions(
      onRetry: canSend ? retried.add : null,
      onEdit: canSend ? edited.add : null,
      onFork: forked.add,
      busy: busy,
      forkPoints: points,
    );

    Widget view(TranscriptTurnActions turnActions, {bool touch = false}) =>
        MaterialApp(
          home: UiDensityScope(
            density: touch ? UiDensity.touch : UiDensity.pointer,
            child: Scaffold(
              body: ChatTranscriptView(
                messages: history,
                turn: TranscriptTurn.idle,
                turnActions: turnActions,
              ),
            ),
          ),
        );

    IconButton button(WidgetTester tester, String id, int at) =>
        tester.widget<IconButton>(find.byKey(ValueKey('chat-turn-$id')).at(at));

    testWidgets('the latest message is sent again at once', (tester) async {
      await tester.pumpWidget(view(actions()));
      // Rows: the first message, its agent row, the second, its agent row.
      await tester.tap(find.byKey(const ValueKey('chat-turn-retry')).at(2));
      await tester.pump();
      expect(retried, ['Now the docs']);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('an earlier one asks first, saying it continues from now', (
      tester,
    ) async {
      await tester.pumpWidget(view(actions()));
      await tester.tap(find.byKey(const ValueKey('chat-turn-retry')).first);
      await tester.pumpAndSettle();
      expect(find.textContaining('continues from now'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(retried, isEmpty);

      // The agent's row retries the message that opened its turn.
      await tester.tap(find.byKey(const ValueKey('chat-turn-retry')).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send again'));
      await tester.pumpAndSettle();
      expect(retried, ['Add a test']);
    });

    testWidgets('Edit and resend is the person\'s row\'s, with their words', (
      tester,
    ) async {
      await tester.pumpWidget(view(actions()));
      expect(find.byKey(const ValueKey('chat-turn-edit')), findsNWidgets(2));
      await tester.tap(find.byKey(const ValueKey('chat-turn-edit')).last);
      await tester.pump();
      expect(edited, ['Now the docs']);
    });

    testWidgets('while a turn runs every action waits, saying why', (
      tester,
    ) async {
      await tester.pumpWidget(view(actions(busy: 'A turn is running.')));
      for (final id in ['retry', 'edit', 'fork']) {
        expect(button(tester, id, 0).onPressed, isNull, reason: id);
        expect(button(tester, id, 0).tooltip, contains('A turn is running.'));
      }
    });

    testWidgets('a session that cannot be sent to offers no Retry or Edit', (
      tester,
    ) async {
      await tester.pumpWidget(view(actions(canSend: false)));
      expect(find.byKey(const ValueKey('chat-turn-retry')), findsNothing);
      expect(find.byKey(const ValueKey('chat-turn-edit')), findsNothing);
      expect(find.byKey(const ValueKey('chat-turn-fork')), findsWidgets);
    });

    testWidgets('Fork waits for a checkpoint, and goes before or after', (
      tester,
    ) async {
      await tester.pumpWidget(
        view(
          actions(
            points: const {
              0: TurnForkPoints(
                before: TurnForkTarget.turn(1),
                after: TurnForkTarget.turn(2),
              ),
            },
          ),
        ),
      );
      // The second turn has no checkpoint: disabled, and says so.
      expect(button(tester, 'fork', 2).onPressed, isNull);
      expect(button(tester, 'fork', 2).tooltip, contains(kNoTurnCheckpoint));

      await tester.tap(find.byKey(const ValueKey('chat-turn-fork')).at(0));
      await tester.tap(find.byKey(const ValueKey('chat-turn-fork')).at(1));
      await tester.pump();
      expect(forked, const [TurnForkTarget.turn(1), TurnForkTarget.turn(2)]);
    });

    testWidgets('Copy turn copies Markdown', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      await tester.pumpWidget(view(actions()));
      await tester.tap(find.byKey(const ValueKey('chat-copy-turn')).first);
      await tester.pump();
      expect(copied, startsWith('### You\n\nAdd a test'));
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('on touch they sit behind ⋯, a waiting one saying why', (
      tester,
    ) async {
      await tester.pumpWidget(view(actions(), touch: true));
      // A tap on the agent's last row shows its meta.
      await tester.tap(find.text('Done.'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-turn-retry')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('chat-turn-more')));
      await tester.pumpAndSettle();
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Fork from here'), findsOneWidget);
      expect(find.text(kNoTurnCheckpoint), findsOneWidget);
      expect(find.text('Copy turn'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(retried, ['Now the docs']);
    });

    testWidgets('fits 360 px at text 1.6 and a desktop', (tester) async {
      for (final touch in [false, true]) {
        await expectSurvivesWindowMatrix(
          tester,
          because: 'a turn\'s actions share its meta row',
          matrix: const [
            WindowCell(
              '360x760 phone, text 1.6',
              Size(360, 760),
              textScale: 1.6,
            ),
            desktopWindow,
          ],
          build: () => view(actions(), touch: touch),
        );
      }
    });
  });
}

class _FakeSessions implements SessionsClient {
  _FakeSessions(this.answer);

  Map<String, Object?> answer;
  final asked = <SessionForkFromCheckpoint>[];

  @override
  Future<Map<String, Object?>> forkFromCheckpoint(
    SessionForkFromCheckpoint request,
  ) async {
    asked.add(request);
    return answer;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
