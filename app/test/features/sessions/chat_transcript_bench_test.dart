@Tags(['cost'])
library;

import 'package:agent_cli/stream.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:karmashala_ui/theme.dart';

/// **The chat at 2,000 turns: what is built, and how long it takes.**
///
/// Timings are printed, never asserted — the suite runs beside other work and
/// a wall-clock bound is a reading of the machine. What is asserted is the
/// countable half: a screen builds a screen's worth of rows, and a streaming
/// tick rebuilds one.
const _turns = 2000;

/// A 900 px screen holds a few dozen rows; generous, and far under 2,000.
const _rowBound = 120;

List<ChatMessage> _conversation({String last = 'streaming'}) => [
  for (var i = 0; i < _turns; i++)
    switch (i % 4) {
      0 => ChatMessage(role: 'user', text: 'Question $i: what does it do?'),
      1 => ChatMessage(
        role: 'tool',
        text: '',
        tool: ToolActivity(
          name: 'Bash',
          subject: 'rg -n "thing$i" lib',
          output: List.generate(
            40,
            (l) => 'lib/file$l.dart:$l: thing',
          ).join('\n'),
        ),
      ),
      2 => ChatMessage(
        role: 'agent',
        text:
            'Here is **turn $i**, with `code` and a list:\n\n'
            '- one\n- two\n\n```dart\nfinal x$i = $i;\n```\n\n'
            '| a | b |\n|---|---|\n| $i | ${i * 2} |',
      ),
      _ => ChatMessage(
        role: 'agent',
        text: i == _turns - 1 ? '$last $i' : 'Done with $i.',
      ),
    },
];

void main() {
  testWidgets('2,000 turns open, scroll to the top and stream', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(tester.view.reset);
    Widget view(List<ChatMessage> messages) => MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(body: ChatTranscriptView(messages: messages)),
    );

    ChatTranscriptView.debugMessageBuildCount = 0;
    final open = Stopwatch()..start();
    await tester.pumpWidget(view(_conversation()));
    await tester.pump();
    open.stop();
    final openBuilds = ChatTranscriptView.debugMessageBuildCount;
    expect(openBuilds, lessThan(_rowBound));

    // A tick of the stream: the list is re-read whole, the last row grows.
    final stream = Stopwatch()..start();
    for (var i = 0; i < 50; i++) {
      ChatTranscriptView.debugMessageBuildCount = 0;
      await tester.pumpWidget(
        view(_conversation(last: 'streaming ${'w ' * i}')),
      );
      await tester.pump();
      expect(ChatTranscriptView.debugMessageBuildCount, lessThanOrEqualTo(1));
    }
    stream.stop();

    // All the way up, a page at a time, then back down.
    final scrollable = find.byType(Scrollable).first;
    final up = Stopwatch()..start();
    var frames = 0;
    while (find.textContaining('Question 0:').evaluate().isEmpty &&
        frames < 4000) {
      await tester.drag(scrollable, const Offset(0, 2000));
      await tester.pump();
      frames++;
    }
    up.stop();
    expect(find.textContaining('Question 0:'), findsOneWidget);

    ChatTranscriptView.debugMessageBuildCount = 0;
    final down = Stopwatch()..start();
    for (var i = 0; i < 40; i++) {
      await tester.drag(scrollable, const Offset(0, -2000));
      await tester.pump();
    }
    down.stop();

    debugPrint(
      'chat bench: $_turns turns · open ${open.elapsedMilliseconds} ms '
      '($openBuilds rows built) · 50 stream ticks '
      '${stream.elapsedMilliseconds} ms '
      '(${(stream.elapsedMicroseconds / 50 / 1000).toStringAsFixed(1)} ms each) · '
      'to the top in $frames drags, ${up.elapsedMilliseconds} ms '
      '(${(up.elapsedMicroseconds / frames / 1000).toStringAsFixed(1)} ms/frame) · '
      '40 drags down ${down.elapsedMilliseconds} ms, '
      '${ChatTranscriptView.debugMessageBuildCount} rows built',
    );
  });
}
