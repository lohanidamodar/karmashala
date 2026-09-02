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

  group("the tile shows the store's own bytes", () {
    // 1b, diagnosed 2026-09-02. `&lt;explicit paths&gt;` on the phone was not
    // introduced anywhere in this app: the agent CLI HTML-escapes a subagent's
    // report when it writes the `<task-notification>` envelope into the parent
    // transcript, and the entity landed inside a code span, where CommonMark
    // keeps it literal. So nothing here escapes — and nothing here unescapes
    // either, because a message may genuinely be quoting an entity.

    testWidgets('angle brackets reach the tile as they were typed', (
      tester,
    ) async {
      await openSession(
        tester,
        gatewayWith(const [
          CompanionChatMessage(
            role: 'user',
            text: 'git commit -F msg -- <explicit paths>',
          ),
          CompanionChatMessage(
            role: 'agent',
            text: 'run `git commit -F msg -- <explicit paths>`',
          ),
        ]),
      );

      expect(
        find.textContaining(
          'git commit -F msg -- <explicit paths>',
          findRichText: true,
        ),
        findsNWidgets(2),
      );
      expect(find.textContaining('&lt;', findRichText: true), findsNothing);
    });

    testWidgets('a message that really quotes &lt; keeps it', (tester) async {
      await openSession(
        tester,
        gatewayWith(const [
          CompanionChatMessage(
            role: 'user',
            text: 'the JSONL holds `&lt;explicit paths&gt;` literally',
          ),
        ]),
      );

      // In a code span, which is both where the phone really showed it and
      // where a downstream "just unescape it" would silently corrupt it.
      expect(
        find.textContaining('&lt;explicit paths&gt;', findRichText: true),
        findsOneWidget,
      );
    });

    for (final scale in const [1.0, 2.0]) {
      testWidgets('a folded task notification reads as machinery at ${scale}x', (
        tester,
      ) async {
        // What the host now sends in place of 7 KB of envelope.
        await openSession(
          tester,
          gatewayWith(const [
            CompanionChatMessage(role: 'user', text: 'go on then'),
            CompanionChatMessage(
              role: 'tool',
              text: 'Agent "Mobile chat scroll to latest" finished',
            ),
          ]),
          textScale: scale,
        );

        expect(
          find.textContaining(
            'Agent "Mobile chat scroll to latest" finished',
            findRichText: true,
          ),
          findsOneWidget,
        );
        // Gutter and label say machine, not person — the point of the choice.
        expect(find.text('TOOL'), findsOneWidget);
        expect(find.text('YOU'), findsOneWidget);
        expect(find.textContaining('subagent_tokens'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('the way back never sits on the newest message', () {
    // 1c, seen on the phone 2026-09-02: the pill floated centred inside the
    // list's viewport, so while it was up it covered a line or two of the
    // newest turn — the very text a reader scrolling back is heading for.
    List<CompanionChatMessage> historyThen(String newest) => [
      for (var i = 0; i < 80; i++)
        CompanionChatMessage(role: 'agent', text: 'old-$i'),
      CompanionChatMessage(role: 'agent', text: newest),
    ];

    final pill = find.widgetWithText(FilledButton, 'Jump to latest');

    for (final scale in const [1.0, 2.0]) {
      testWidgets('at a ${scale}x text scale', (tester) async {
        await openSession(
          tester,
          gatewayWith(historyThen('the-newest-word')),
          textScale: scale,
        );

        // The smallest move that raises the pill, so the newest turn has
        // barely begun to leave the bottom — the state that hid it.
        positionOf(tester).jumpTo(30);
        await tester.pump();
        expect(pill, findsOneWidget);

        // Outside the list entirely, so no transcript pixel can be under it —
        // and no pill height to keep a padding constant in step with as the
        // text scale moves it.
        expect(
          tester.getRect(pill).overlaps(tester.getRect(find.byType(ListView))),
          isFalse,
        );

        final newest = find.text('the-newest-word', findRichText: true);
        expect(newest, findsOneWidget);
        expect(
          tester.getRect(newest).top,
          lessThan(tester.getRect(pill).top),
          reason: 'the newest turn begins above the pill, not under it',
        );
      });
    }

    testWidgets('and the list gets its room back when the pill goes', (
      tester,
    ) async {
      await openSession(tester, gatewayWith(historyThen('the-newest-word')));
      final listBefore = tester.getRect(find.byType(ListView));

      positionOf(tester).jumpTo(30);
      await tester.pump();
      expect(
        tester.getRect(find.byType(ListView)).height,
        lessThan(listBefore.height),
      );

      await tester.tap(pill);
      await tester.pumpAndSettle();

      expect(pill, findsNothing);
      expect(positionOf(tester).pixels, 0);
      expect(tester.getRect(find.byType(ListView)), listBefore);
    });
  });
}
