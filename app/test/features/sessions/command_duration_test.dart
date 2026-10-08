import 'package:agent_cli/stream.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:karmashala/src/features/sessions/presentation/tool_run.dart';

import '../../support/window_matrix.dart';

/// A command says how long it took beside how it ended, read off its call's
/// own start and end; nothing where either went unrecorded; and while it
/// runs, its time ticks on the transcript's one timer.
void main() {
  final t0 = DateTime.utc(2026, 10, 8, 10);

  ChatMessage bash(
    String command, {
    DateTime? at,
    DateTime? endedAt,
    bool pending = false,
    String? output = 'ok',
  }) => ChatMessage(
    role: 'tool',
    text: 'Bash($command)',
    at: at,
    pending: pending,
    tool: ToolActivity(
      name: 'Bash',
      subject: command,
      output: pending ? null : output,
      endedAt: endedAt,
    ),
  );

  String textOf(WidgetTester tester, String key) =>
      tester.widget<Text>(find.byKey(ValueKey(key)).first).data!;

  group('the words', () {
    test('tenths under ten seconds, then the elapsed form', () {
      expect(formatCommandDuration(const Duration(milliseconds: 2400)), '2.4s');
      expect(formatCommandDuration(const Duration(milliseconds: 40)), '0.0s');
      expect(formatCommandDuration(const Duration(seconds: 12)), '12s');
      expect(
        formatCommandDuration(const Duration(minutes: 1, seconds: 12)),
        '1m 12s',
      );
    });

    test('only a command with both ends recorded has one', () {
      final ran = bash(
        'ls',
        at: t0,
        endedAt: t0.add(const Duration(milliseconds: 2400)),
      );
      expect(commandDuration(ran), const Duration(milliseconds: 2400));
      expect(commandDuration(bash('ls', at: t0)), isNull);
      expect(commandDuration(bash('ls', endedAt: t0)), isNull);
      expect(commandDuration(bash('ls', at: t0, pending: true)), isNull);
      final read = ChatMessage(
        role: 'tool',
        text: 'Read',
        at: t0,
        tool: ToolActivity(name: 'Read', endedAt: t0.add(Durations.long1)),
      );
      expect(commandDuration(read), isNull, reason: 'not a command');
    });
  });

  Widget view(
    List<ChatMessage> messages, {
    TranscriptTurn turn = TranscriptTurn.working,
    DateTime Function()? now,
  }) => MaterialApp(
    home: Scaffold(
      body: ChatTranscriptView(messages: messages, turn: turn, now: now),
    ),
  );

  testWidgets('recorded, it is drawn; missing, nothing is', (tester) async {
    await tester.pumpWidget(
      view([
        const ChatMessage(role: 'user', text: 'Check it'),
        bash(
          'dart test',
          at: t0,
          endedAt: t0.add(const Duration(milliseconds: 2400)),
        ),
        bash('ls', at: t0),
      ]),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('command-duration')), findsOneWidget);
    expect(textOf(tester, 'command-duration'), '2.4s');
  });

  testWidgets('a running command ticks, once a second', (tester) async {
    var now = t0.add(const Duration(seconds: 5));
    await tester.pumpWidget(
      view([
        const ChatMessage(role: 'user', text: 'Build it'),
        bash('make', at: t0, pending: true),
      ], now: () => now),
    );
    await tester.pump();
    expect(textOf(tester, 'command-running-time'), '5s');

    now = now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(textOf(tester, 'command-running-time'), '6s');

    // The turn over, the timer is gone: nothing is left ticking.
    await tester.pumpWidget(
      view(
        [
          const ChatMessage(role: 'user', text: 'Build it'),
          bash('make', at: t0, endedAt: t0.add(const Duration(seconds: 7))),
        ],
        turn: TranscriptTurn.idle,
        now: () => now,
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('command-running-time')), findsNothing);
  });

  testWidgets('a settled run names each command\'s time when opened', (
    tester,
  ) async {
    await tester.pumpWidget(
      view([
        const ChatMessage(role: 'user', text: 'Go'),
        bash(
          'flutter build',
          at: t0,
          endedAt: t0.add(const Duration(minutes: 1, seconds: 12)),
        ),
        const ChatMessage(role: 'agent', text: 'Built.'),
      ], turn: TranscriptTurn.idle),
    );
    await tester.pump();
    await tester.tap(find.textContaining('Ran 1 command'));
    await tester.pump();
    expect(textOf(tester, 'command-duration'), ' · 1m 12s');
  });

  testWidgets('fits 360 px at text 1.6 and a desktop', (tester) async {
    await expectSurvivesWindowMatrix(
      tester,
      because: 'a command\'s time sits on its one line',
      matrix: const [
        WindowCell('360x760 phone, text 1.6', Size(360, 760), textScale: 1.6),
        desktopWindow,
      ],
      build: () => view([
        const ChatMessage(role: 'user', text: 'Check it'),
        bash(
          'dart test --exclude-tags=live-ssh,live-wsl a/very/long/path',
          at: t0,
          endedAt: t0.add(const Duration(minutes: 3, seconds: 40)),
          output: 'Exit code 1',
        ),
        bash('ls', at: t0, pending: true),
      ], now: () => t0.add(const Duration(seconds: 9))),
    );
  });
}
