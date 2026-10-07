import 'package:agent_cli/read.dart' show kTranscriptNoticeRole;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';

import '../../support/window_matrix.dart';

/// A finished turn closes with one quiet line, as Claude Code's terminal does
/// (`✻ Crunched for 6s · done 6:07 PM`), timed by the record's own stamps so
/// old turns and resumed sessions get it too.
void main() {
  // Local, so the clock the footer prints is the one written here.
  final asked = DateTime(2026, 10, 7, 18, 7);

  ChatMessage said(
    String role,
    String text,
    DateTime? at, {
    bool queued = false,
  }) => ChatMessage(role: role, text: text, at: at, queued: queued);

  DateTime after(int seconds) => asked.add(Duration(seconds: seconds));

  group('which turns get one', () {
    test('every finished turn, timed from the person to the agent', () {
      final footers = turnFooters([
        said('user', 'Fix it', asked),
        said('tool', 'Bash(ls)', after(2)),
        said('agent', 'Fixed.', after(6)),
        said('user', 'Thanks', after(60)),
        said('agent', 'Any time.', after(64)),
      ], lastTurnOver: true);
      expect(footers.keys, [2, 4]);
      expect(footers[2]!.elapsed, const Duration(seconds: 6));
      expect(footers[2]!.ending, TurnEnding.done);
      expect(footers[4]!.elapsed, const Duration(seconds: 4));
    });

    test('not the turn still running', () {
      final footers = turnFooters([
        said('user', 'Fix it', asked),
        said('agent', 'Fixed.', after(6)),
        said('user', 'And the docs', after(60)),
        said('agent', 'On it.', after(61)),
      ], lastTurnOver: false);
      expect(footers.keys, [1]);
    });

    test('a stopped turn and a failed one say so', () {
      final footers = turnFooters([
        said('user', 'Fix it', asked),
        said('agent', 'Looking.', after(2)),
        said('user', '[Request interrupted by user]', after(6)),
        said('user', 'Try again', after(10)),
        said('error', 'API Error: overloaded', after(13)),
        said('user', 'Once more', after(20)),
        said(kTranscriptNoticeRole, 'Interrupted by you', after(25)),
      ], lastTurnOver: true);
      expect(footers[2]!.ending, TurnEnding.stopped);
      expect(footers[2]!.elapsed, const Duration(seconds: 6));
      expect(footers[4]!.ending, TurnEnding.failed);
      expect(footers[4]!.elapsed, const Duration(seconds: 3));
      expect(footers[6]!.ending, TurnEnding.stopped, reason: 'Codex says so');
    });

    test('a missing stamp is no footer, never a guess', () {
      final footers = turnFooters([
        said('user', 'Fix it', null),
        said('agent', 'Fixed.', after(6)),
        said('user', 'Thanks', after(60)),
        said('agent', 'Any time.', null),
      ], lastTurnOver: true);
      expect(footers, isEmpty);
    });

    test('a message waiting in the queue does not open a turn', () {
      final footers = turnFooters([
        said('user', 'Fix it', asked),
        said('agent', 'Fixed.', after(6)),
        said('user', 'Next', after(3), queued: true),
      ], lastTurnOver: true);
      expect(footers.keys, [1]);
      expect(footers[1]!.elapsed, const Duration(seconds: 6));
    });
  });

  group('how it reads', () {
    Future<void> pump(
      WidgetTester tester,
      List<ChatMessage> messages, {
      bool twentyFour = false,
      String? verb,
      int? tokens,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(alwaysUse24HourFormat: twentyFour),
            child: Scaffold(
              body: ChatTranscriptView(
                messages: messages,
                turn: TranscriptTurn.idle,
                lastTurnVerb: verb,
                lastTurnTokens: tokens,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    final history = [
      said('user', 'Fix it', asked),
      said('agent', 'Fixed.', after(6)),
      said('user', 'Thanks', after(60)),
      said('agent', 'Any time.', after(64)),
    ];

    testWidgets('the latest in the agent\'s word, older ones as Worked', (
      tester,
    ) async {
      await pump(tester, history, verb: 'Crunched', tokens: 1234);
      expect(find.text('Worked for 6s · done 6:07 PM'), findsOneWidget);
      expect(
        find.text('Crunched for 4s · 1.2k tokens · done 6:08 PM'),
        findsOneWidget,
      );
    });

    testWidgets('a 24-hour clock where the device keeps one', (tester) async {
      await pump(tester, history, twentyFour: true);
      expect(find.text('Worked for 6s · done 18:07'), findsOneWidget);
      expect(find.text('Worked for 4s · done 18:08'), findsOneWidget);
    });

    testWidgets('stopped and failed', (tester) async {
      await pump(tester, [
        said('user', 'Fix it', asked),
        said('user', '[Request interrupted by user]', after(6)),
        said('user', 'Again', after(10)),
        said('error', 'API Error: overloaded', after(13)),
      ]);
      expect(find.text('Stopped after 6s · 6:07 PM'), findsOneWidget);
      expect(find.text('Failed after 3s · 6:07 PM'), findsOneWidget);
    });

    testWidgets('survives 360 px at text scale 1.6, and a desktop', (
      tester,
    ) async {
      await expectSurvivesWindowMatrix(
        tester,
        because: 'the footer is one line however narrow the chat',
        matrix: const [
          WindowCell('360x760 phone, text 1.6', Size(360, 760), textScale: 1.6),
          desktopWindow,
        ],
        build: () => MaterialApp(
          home: Scaffold(
            body: ChatTranscriptView(
              messages: [
                said('user', 'Fix it', asked),
                said('agent', 'Fixed.', after(3725)),
              ],
              turn: TranscriptTurn.idle,
              lastTurnVerb: 'Discombobulated',
              lastTurnTokens: 123456,
            ),
          ),
        ),
      );
    });
  });
}
