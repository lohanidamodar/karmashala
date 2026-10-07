import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:karmashala_ui/theme.dart';

/// **"New since you last looked"** in a conversation: the line above the
/// first message after the last look, older ones folded behind "Load".
void main() {
  final t0 = DateTime.utc(2026, 10, 7, 9);
  List<ChatMessage> conversation(int n) => [
    for (var i = 0; i < n; i++)
      ChatMessage(
        role: i.isEven ? 'user' : 'agent',
        text: 'message $i',
        at: t0.add(Duration(minutes: i)),
      ),
  ];

  Future<void> pump(WidgetTester tester, Widget view) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.dark(), home: Scaffold(body: view)),
    );
    await tester.pump();
  }

  testWidgets('the line sits above the first new message, older ones fold', (
    tester,
  ) async {
    await pump(
      tester,
      ChatTranscriptView(
        messages: conversation(12),
        // Messages 0–7 were seen; 8–11 came after.
        seenUntil: t0.add(const Duration(minutes: 7, seconds: 30)),
      ),
    );
    final line = find.byKey(const ValueKey('chat-new-since'));
    expect(line, findsOneWidget);
    expect(find.text('New since you last looked'), findsOneWidget);
    expect(
      tester.getTopLeft(line).dy,
      lessThan(tester.getTopLeft(find.text('message 8')).dy),
    );
    expect(
      tester.getTopLeft(line).dy,
      greaterThan(tester.getTopLeft(find.text('message 7')).dy),
    );
    // Three kept before the line; the rest behind "Load".
    expect(find.text('message 5'), findsOneWidget);
    expect(find.text('message 4'), findsNothing);
    expect(find.text('Load 5 earlier messages'), findsOneWidget);
  });

  testWidgets('nothing new, or never looked: no line, nothing folded', (
    tester,
  ) async {
    await pump(
      tester,
      ChatTranscriptView(
        messages: conversation(6),
        seenUntil: t0.add(const Duration(hours: 1)),
      ),
    );
    expect(find.byKey(const ValueKey('chat-new-since')), findsNothing);
    await pump(tester, ChatTranscriptView(messages: conversation(6)));
    expect(find.byKey(const ValueKey('chat-new-since')), findsNothing);
    expect(find.text('message 0'), findsOneWidget);
  });
}
