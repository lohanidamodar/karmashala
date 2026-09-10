import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala/src/features/companion/presentation/companion_composer.dart';
import 'package:karmashala/src/features/companion/presentation/session_view_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'companion_test_support.dart';

/// The phone's message box, at the one thing it is for: getting a prompt to
/// the agent.
///
/// **The keyboard's own key is a send, not a line break.** The composer's only
/// keyboard route to the transport is `onSubmitted`, and `EditableText` calls
/// it from `performAction` — with whatever action the platform reports. On
/// Android that action is the IME's, and an IME reads the field's *input type*
/// to decide what key to draw: `TextInputType.multiline` says "this field
/// takes newlines", so the action key becomes Return and pressing it inserts a
/// line break instead of reporting an action. `TextField` picks that input
/// type for itself whenever `maxLines != 1`
/// (`text_field.dart`: `keyboardType ?? (maxLines == 1 ? text : multiline)`),
/// so a growing message box silently opts out of its own
/// `textInputAction: TextInputAction.send` — the owner's *"it only types the
/// message but don't send"*.
///
/// `tester.testTextInput.receiveAction` deliberately "does not check that the
/// [TextInputAction] performed is an acceptable one based on the `inputAction`
/// [setClientArgs]", so injecting `send` proves nothing about whether a real
/// keyboard would ever send it. The configuration the phone hands the platform
/// is the fact under test, and it is asserted directly.
void main() {
  FakeCompanionGateway gateway() => FakeCompanionGateway.paired(
    sessions: [summary('s1', title: 'Fix the login flow')],
    transcripts: {
      's1': const [CompanionChatMessage(role: 'agent', text: 'ready')],
    },
  );

  /// The `TextInput.setClient` configuration the focused composer registered —
  /// the same description an Android IME reads to choose its action key.
  Map<String, dynamic> imeContract(WidgetTester tester) {
    final args = tester.testTextInput.setClientArgs;
    expect(args, isNotNull, reason: 'the composer never attached to the IME');
    return args!;
  }

  group('the send bug', () {
    for (final (name, size) in [
      ('phone', kPhoneSize),
      ('tablet', kTabletSize),
    ]) {
      testWidgets('$name: the keyboard is asked for a Send key', (
        tester,
      ) async {
        await pumpPhone(
          tester,
          gateway: gateway(),
          home: const SessionViewScreen(sessionId: 's1'),
          size: size,
        );
        await tester.tap(find.byType(TextField));
        await tester.pump();

        final contract = imeContract(tester);
        expect(
          (contract['inputType'] as Map)['name'],
          'TextInputType.text',
          reason:
              'a multiline input type makes the IME draw Return instead of '
              'Send, so the keyboard can never reach onSubmitted',
        );
        expect(contract['inputAction'], 'TextInputAction.send');
      });
    }

    testWidgets('the keyboard action reaches the transport exactly once', (
      tester,
    ) async {
      final fake = gateway();
      await pumpPhone(
        tester,
        gateway: fake,
        home: const SessionViewScreen(sessionId: 's1'),
      );

      await tester.enterText(find.byType(TextField), 'run the tests');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      expect(fake.sentPrompts, [(sessionId: 's1', text: 'run the tests')]);
      // Sent means gone from the box: text left behind is the same "did that
      // send?" the bug was.
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty,
      );
    });

    testWidgets('the send button reaches the transport exactly once', (
      tester,
    ) async {
      final fake = gateway();
      await pumpPhone(
        tester,
        gateway: fake,
        home: const SessionViewScreen(sessionId: 's1'),
      );

      await tester.enterText(find.byType(TextField), 'ship it');
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();

      expect(fake.sentPrompts, [(sessionId: 's1', text: 'ship it')]);
    });

    testWidgets('the box keeps the keyboard for the next message', (
      tester,
    ) async {
      await pumpPhone(
        tester,
        gateway: gateway(),
        home: const SessionViewScreen(sessionId: 's1'),
      );

      await tester.enterText(find.byType(TextField), 'and again');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      // `TextInputAction.send` unfocuses inside `EditableText`; a keyboard
      // that closes after every turn reads as the session having ended.
      expect(
        tester
            .widget<TextField>(find.byType(TextField))
            .focusNode
            ?.hasPrimaryFocus,
        isTrue,
      );
    });

    testWidgets('an empty box sends nothing, by either route', (tester) async {
      final fake = gateway();
      await pumpPhone(
        tester,
        gateway: fake,
        home: const SessionViewScreen(sessionId: 's1'),
      );

      await tester.enterText(find.byType(TextField), '   ');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();

      expect(fake.sentPrompts, isEmpty);
    });

    testWidgets('a dropped link keeps the draft for retry', (tester) async {
      final fake = gateway();
      await pumpPhone(
        tester,
        gateway: fake,
        home: const SessionViewScreen(sessionId: 's1'),
      );

      await tester.enterText(find.byType(TextField), 'send when back online');
      fake.setLink(CompanionLinkState.disconnected);
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();

      expect(fake.sentPrompts, isEmpty);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        'send when back online',
      );
    });
  });

  // --- The box a thumb writes in --------------------------------------------
  //
  // The owner, of the desktop's: "message enter prompt field is very small and
  // too much spacing". The phone's had the same shape of problem for a
  // different reason — measured at 390x844, `contentPadding: EdgeInsets.zero`
  // left the field **24px** tall inside an 83px bar, so the control the whole
  // screen exists for was half the touch floor while the bar around it was
  // not.
  group('the message box is a target, not a strip', () {
    for (final (name, size) in [
      ('phone', kPhoneSize),
      ('tablet', kTabletSize),
    ]) {
      testWidgets('$name: the field clears the touch floor', (tester) async {
        await pumpPhone(
          tester,
          gateway: gateway(),
          home: const SessionViewScreen(sessionId: 's1'),
          size: size,
        );

        final field = find.byType(TextField);
        expect(
          tester.getSize(field).height,
          greaterThanOrEqualTo(Touch.target),
          reason: 'tapping the box has to be as easy as tapping Send',
        );
        // And the box is the tall thing in the bar, not the chrome around it.
        final bar = tester.getSize(find.byType(CompanionComposer));
        expect(
          tester.getSize(field).height * 2,
          greaterThan(bar.height),
          reason: 'more than half the composer is the field itself',
        );
      });
    }

    testWidgets('the hint is the size of the text that replaces it', (
      tester,
    ) async {
      await pumpPhone(
        tester,
        gateway: gateway(),
        home: const SessionViewScreen(sessionId: 's1'),
      );

      final field = tester.widget<TextField>(find.byType(TextField));
      // The hint was a step down the ramp from the typed text, so the field's
      // text changed size the moment anything was typed into it.
      expect(
        field.decoration?.hintStyle?.fontSize,
        field.style?.fontSize,
      );
      // Not the app's smallest step, either: this is read at arm's length.
      final theme = Theme.of(tester.element(find.byType(TextField)));
      expect(field.style?.fontSize, theme.textTheme.bodyLarge?.fontSize);
    });

    testWidgets('the pill is the only surface the box paints on', (
      tester,
    ) async {
      await pumpPhone(
        tester,
        gateway: gateway(),
        home: const SessionViewScreen(sessionId: 's1'),
      );

      // `inputDecorationTheme` sets `filled: true`, and a filled decoration
      // still paints under `InputBorder.none` — its outer path is a plain
      // rect — which put a hard-edged box inside the rounded capsule.
      expect(
        tester.widget<TextField>(find.byType(TextField)).decoration?.filled,
        isFalse,
      );
    });
  });
}
