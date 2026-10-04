import 'package:agent_cli/stream.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:agent_cli/read.dart' show TranscriptMessage;

/// **A command an ACP agent runs in a client terminal shows its output live**,
/// under the tool call that embeds the terminal: the server folds what the
/// terminal printed into the call while it still runs (pending), and again as
/// it grows, and the call stays "running" until it ends.
void main() {
  final at = DateTime.utc(2026, 10, 4, 12);

  /// The row as the server's transcript projection serves a terminal call.
  TranscriptMessage call(String? output, {bool running = true}) =>
      TranscriptMessage(
        role: 'tool',
        text: '',
        at: at,
        tool: ToolActivity(name: 'npm test', output: output),
        pendingToolUseId: running ? 'c1' : null,
      );

  Widget view(TranscriptMessage tool, {required TranscriptTurn turn}) =>
      MaterialApp(
        home: Scaffold(
          body: ChatTranscriptView(
            messages: chatMessagesFromTranscript([
              TranscriptMessage(role: 'user', text: 'run the tests', at: at),
              TranscriptMessage(role: 'agent', text: 'Running them.', at: at),
              tool,
            ]),
            turn: turn,
          ),
        ),
      );

  Finder shown(String text) => find.textContaining(text, findRichText: true);

  /// Opens whatever line folds the call, once, so its card is drawn.
  Future<void> open(WidgetTester tester) async {
    if (shown('compiling').evaluate().isNotEmpty) return;
    for (final label in ['Working', 'Used 1 tool', 'npm test']) {
      final line = find.textContaining(label);
      if (line.evaluate().isEmpty) continue;
      await tester.tap(line.first);
      await tester.pumpAndSettle();
      if (shown('compiling').evaluate().isNotEmpty) return;
    }
  }

  testWidgets('the output so far shows while the command runs, and grows', (
    tester,
  ) async {
    await tester.pumpWidget(
      view(call('compiling…'), turn: TranscriptTurn.working),
    );
    await tester.pumpAndSettle();
    await open(tester);

    expect(shown('compiling…'), findsWidgets);
    // Output does not settle it: the row the chat draws is still pending.
    expect(
      chatMessagesFromTranscript([call('compiling…')]).single.pending,
      isTrue,
    );

    await tester.pumpWidget(
      view(call('compiling…\nlinking…'), turn: TranscriptTurn.working),
    );
    await tester.pumpAndSettle();
    await open(tester);
    expect(shown('linking…'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a running command that has printed nothing shows no output', (
    tester,
  ) async {
    await tester.pumpWidget(view(call(null), turn: TranscriptTurn.working));
    await tester.pumpAndSettle();
    await open(tester);
    expect(shown('compiling'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('once it ends, the whole output stays under the call', (
    tester,
  ) async {
    await tester.pumpWidget(
      view(
        call('compiling…\nall 42 passed', running: false),
        turn: TranscriptTurn.idle,
      ),
    );
    await tester.pumpAndSettle();
    await open(tester);
    expect(shown('all 42 passed'), findsWidgets);
    expect(
      chatMessagesFromTranscript([call('x', running: false)]).single.pending,
      isFalse,
    );
  });
}
