import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/companion/client/companion_gateway.dart';
import 'package:karmashala/src/features/companion/client/fake_companion_gateway.dart';
import 'package:karmashala/src/features/companion/presentation/session_view_screen.dart';

import 'companion_test_support.dart';

/// The phone's chat, at the one end a reader looks for: its newest message.
///
/// The desktop list jumped once to a lazily-*estimated* `maxScrollExtent`, so a
/// session whose newest turns are its longest opened thousands of pixels short
/// of the end — the "I cannot find the edge of the session" report. These pin
/// the four behaviours that answer it: land on the newest, follow only when
/// already there, offer a way back, and name the top of the loaded window.
void main() {
  /// The shape that broke it: a long history of one-liners, then the newest
  /// turns as the long agent answers real sessions end with.
  List<CompanionChatMessage> unevenTranscript() => [
    for (var i = 0; i < 290; i++)
      CompanionChatMessage(role: i.isEven ? 'user' : 'agent', text: 'old-$i'),
    for (var i = 0; i < 10; i++)
      CompanionChatMessage(
        role: 'agent',
        text: 'tall-$i\n${List.filled(30, 'a long paragraph line').join('\n\n')}',
      ),
  ];

  ScrollPosition positionOf(WidgetTester tester) => tester
      .state<ScrollableState>(
        find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      )
      .position;

  FakeCompanionGateway gatewayWith(List<CompanionChatMessage> messages) =>
      FakeCompanionGateway.paired(
        sessions: [summary('s1', title: 'Fix the login flow')],
        transcripts: {'s1': messages},
      );

  Future<void> openSession(
    WidgetTester tester,
    FakeCompanionGateway gateway, {
    double textScale = 1.0,
  }) async {
    await pumpPhone(
      tester,
      gateway: gateway,
      home: const SessionViewScreen(sessionId: 's1'),
      textScale: textScale,
    );
    await tester.pump();
  }

  testWidgets('opening a long session lands on its newest message', (
    tester,
  ) async {
    await openSession(tester, gatewayWith(unevenTranscript()));

    // Reversed: offset zero *is* the newest message, so there is no estimate
    // to be wrong about and the last turn is on screen from the first frame.
    expect(positionOf(tester).pixels, 0);
    expect(find.textContaining('tall-9', findRichText: true), findsOneWidget);
    expect(find.textContaining('tall-0', findRichText: true), findsNothing);
  });

  testWidgets('a message that arrives while you are at the newest follows', (
    tester,
  ) async {
    final gateway = gatewayWith(unevenTranscript());
    await openSession(tester, gateway);

    gateway.appendMessage(
      's1',
      const CompanionChatMessage(role: 'agent', text: 'the-newest-word'),
    );
    await tester.pump();
    await tester.pump();

    expect(positionOf(tester).pixels, 0);
    expect(find.text('the-newest-word', findRichText: true), findsOneWidget);
  });

  testWidgets('a message that arrives while you read history leaves you put', (
    tester,
  ) async {
    final gateway = gatewayWith(unevenTranscript());
    await openSession(tester, gateway);

    // Away from the newest message, into the history above it.
    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await tester.pumpAndSettle();
    final before = positionOf(tester).pixels;
    expect(before, greaterThan(0));

    gateway.appendMessage(
      's1',
      const CompanionChatMessage(role: 'agent', text: 'the-newest-word'),
    );
    await tester.pump();
    await tester.pump();

    expect(positionOf(tester).pixels, before);
    expect(find.text('the-newest-word', findRichText: true), findsNothing);
  });

  testWidgets('jump to latest appears only off the end, and goes back', (
    tester,
  ) async {
    await openSession(tester, gatewayWith(unevenTranscript()));
    expect(find.text('Jump to latest'), findsNothing);

    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await tester.pumpAndSettle();
    expect(find.text('Jump to latest'), findsOneWidget);

    await tester.tap(find.text('Jump to latest'));
    await tester.pumpAndSettle();

    expect(positionOf(tester).pixels, 0);
    expect(find.text('Jump to latest'), findsNothing);
    expect(find.textContaining('tall-9', findRichText: true), findsOneWidget);
  });

  testWidgets('a short transcript that fits offers no way back', (tester) async {
    await openSession(
      tester,
      gatewayWith(const [
        CompanionChatMessage(role: 'user', text: 'hello'),
        CompanionChatMessage(role: 'agent', text: 'hi'),
      ]),
    );

    expect(find.text('Jump to latest'), findsNothing);
    // Oldest first still reads oldest-first, however the list is built.
    expect(
      tester.getCenter(find.text('hello', findRichText: true)).dy,
      lessThan(tester.getCenter(find.text('hi', findRichText: true)).dy),
    );
  });

  testWidgets('the omitted marker names the top of the loaded window', (
    tester,
  ) async {
    await openSession(
      tester,
      gatewayWith(const [
        CompanionChatMessage(
          role: kCompanionNoticeRole,
          text: '2,400 earlier messages are not loaded — this is the top of '
              'what the phone has. The desktop holds the whole conversation.',
        ),
        CompanionChatMessage(role: 'user', text: 'hello'),
        CompanionChatMessage(role: 'agent', text: 'hi'),
      ]),
    );

    expect(find.textContaining('are not loaded'), findsOneWidget);
    // Not a turn: it borrows no message's gutter, so it cannot be read as
    // something the agent said — or as the end of the conversation.
    expect(find.text('TOOL'), findsNothing);
    expect(
      tester.getCenter(find.textContaining('are not loaded')).dy,
      lessThan(tester.getCenter(find.text('hello', findRichText: true)).dy),
    );
  });

  testWidgets('nothing is said when the whole conversation was sent', (
    tester,
  ) async {
    await openSession(
      tester,
      gatewayWith(const [
        CompanionChatMessage(role: 'user', text: 'hello'),
        CompanionChatMessage(role: 'agent', text: 'hi'),
      ]),
    );

    expect(find.textContaining('are not loaded'), findsNothing);
  });

  testWidgets('the chat and its way back survive a 200% text scale', (
    tester,
  ) async {
    await openSession(tester, gatewayWith(unevenTranscript()), textScale: 2.0);
    expect(positionOf(tester).pixels, 0);

    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await tester.pumpAndSettle();

    expect(find.text('Jump to latest'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
