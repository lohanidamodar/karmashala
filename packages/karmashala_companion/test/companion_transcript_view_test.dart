import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_companion/screens.dart';
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
        text:
            'tall-$i\n${List.filled(30, 'a long paragraph line').join('\n\n')}',
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

  testWidgets('a short transcript that fits offers no way back', (
    tester,
  ) async {
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
          text:
              '2,400 earlier messages are not loaded — this is the top of '
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
      testWidgets(
        'a folded task notification reads as machinery at ${scale}x',
        (tester) async {
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
        },
      );
    }
  });

  // --- Which nothing it is -------------------------------------------------
  //
  // "I have a running antigravity session and in the mobile companion app it
  // shows running, but when I open it, it doesn't show any transcript." The
  // host knew why — that agent keeps no store this app can read — and the
  // phone drew a welcome screen with starter prompts on it, which is the one
  // thing that reads as "this screen is broken" for a session already mid-run.
  group('an empty transcript says which nothing it is', () {
    const reason = CompanionChatMessage(
      role: kCompanionAbsenceRole,
      text:
          'This agent keeps no transcript this app can read, so there is no '
          'chat view for it — on the desktop or here.',
    );

    FakeCompanionGateway gateway({
      List<CompanionChatMessage> messages = const [],
      CompanionSessionStatus status = CompanionSessionStatus.working,
    }) => FakeCompanionGateway.paired(
      sessions: [summary('s1', title: 'Running now', status: status)],
      transcripts: {'s1': messages},
    );

    for (final (name, size) in [
      ('phone', kPhoneSize),
      ('tablet', kTabletSize),
    ]) {
      testWidgets('$name: the reason is the screen, not a welcome', (
        tester,
      ) async {
        await pumpPhone(
          tester,
          gateway: gateway(messages: const [reason]),
          home: const SessionViewScreen(sessionId: 's1'),
          size: size,
        );
        await tester.pump();

        expect(find.textContaining('no chat view for it'), findsOneWidget);
        // Not onboarding, and not a turn: no invitation to start something
        // that is already running, and no gutter that reads as the agent.
        expect(find.text('Start a conversation'), findsNothing);
        expect(find.text('Explain architecture'), findsNothing);
        expect(find.text('AGENT'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('the other structural nothing is its own sentence, under the '
        'same heading', (tester) async {
      // The heading is true of both — there is no chat view either way — and
      // the sentence under it is the half that differs, so the screen shows
      // whichever the host sent rather than one wording for two facts.
      await pumpPhone(
        tester,
        gateway: gateway(
          messages: const [
            CompanionChatMessage(
              role: kCompanionAbsenceRole,
              text:
                  'This session\'s store kept the conversation and no '
                  'transcript this app can read beside it, so there is no '
                  'chat view for it — on the desktop or here.',
            ),
          ],
        ),
        home: const SessionViewScreen(sessionId: 's1'),
      );
      await tester.pump();

      expect(find.text('No chat view for this session'), findsOneWidget);
      expect(find.textContaining('kept the conversation'), findsOneWidget);
      expect(find.textContaining('This agent keeps'), findsNothing);
      expect(find.text('Start a conversation'), findsNothing);
    });

    testWidgets('a session that has not started is still welcomed', (
      tester,
    ) async {
      await pumpPhone(
        tester,
        gateway: gateway(status: CompanionSessionStatus.idle),
        home: const SessionViewScreen(sessionId: 's1'),
      );
      await tester.pump();

      expect(find.text('Start a conversation'), findsOneWidget);
      expect(find.text('Explain architecture'), findsOneWidget);

      // A chip writes the prompt and stops — the composer sends it.
      await tester.tap(find.text('Explain architecture'));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        startsWith('Explain the architecture'),
      );
    });

    testWidgets('a session already working is offered no starter prompts', (
      tester,
    ) async {
      await pumpPhone(
        tester,
        gateway: gateway(status: CompanionSessionStatus.working),
        home: const SessionViewScreen(sessionId: 's1'),
      );
      await tester.pump();

      expect(find.text('Explain architecture'), findsNothing);
      // The hedge is still said out loud: with no reason from the host, both
      // nothings are still possible and the phone claims neither.
      expect(
        find.textContaining('their terminal is the session'),
        findsOneWidget,
      );
    });
  });

  // --- What a message spends its height on ---------------------------------
  //
  // Measured at 390x844: a copy `IconButton` at the touch floor made every
  // tile's gutter 48px tall to carry an 11px label, so a one-line message
  // spent 72px of the list on 20px of text and three of them took a fifth of
  // the transcript viewport on chrome.
  group('a message spends its height on its text', () {
    const three = [
      CompanionChatMessage(role: 'user', text: 'one'),
      CompanionChatMessage(role: 'agent', text: 'two'),
      CompanionChatMessage(role: 'tool', text: 'three'),
    ];

    Size gutterOf(WidgetTester tester, String label) => tester.getSize(
      find.ancestor(of: find.text(label), matching: find.byType(Row)).first,
    );

    for (final (name, size) in [
      ('phone', kPhoneSize),
      ('tablet', kTabletSize),
    ]) {
      testWidgets('$name: the gutter is sized by its label', (tester) async {
        await pumpPhone(
          tester,
          gateway: gatewayWith(three),
          home: const SessionViewScreen(sessionId: 's1'),
          size: size,
        );
        await tester.pump();

        for (final label in ['YOU', 'AGENT', 'TOOL']) {
          expect(
            gutterOf(tester, label).height,
            lessThan(Touch.target),
            reason: '$label: a row of chrome must not cost a whole target',
          );
        }
      });
    }

    testWidgets('every message is still selectable, which is the copy', (
      tester,
    ) async {
      await pumpPhone(
        tester,
        gateway: gatewayWith(three),
        home: const SessionViewScreen(sessionId: 's1'),
      );
      await tester.pump();

      // What the copy button was for. One selection area over the list: a
      // long press raises the platform's selection toolbar — a target the
      // system draws, at its own sizes — on every role, tool rows included.
      // `companion_transcript_selection_test` drives it.
      expect(
        find.ancestor(
          of: find.text('three'),
          matching: find.byType(SelectionArea),
        ),
        findsOneWidget,
      );
    });

    testWidgets('message text is not the app\'s smallest step', (tester) async {
      await pumpPhone(
        tester,
        gateway: gatewayWith(three),
        home: const SessionViewScreen(sessionId: 's1'),
      );
      await tester.pump();

      final theme = Theme.of(tester.element(find.byType(ListView)));
      final tool = tester.widget<Text>(find.text('three'));
      expect(
        tool.style?.fontSize,
        theme.textTheme.bodyMedium?.fontSize,
        reason:
            'a tool row was `bodySmall`, the ramp\'s 12, on the phone\'s '
            'most-read screen',
      );
    });
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
