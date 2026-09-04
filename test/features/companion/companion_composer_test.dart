import 'package:karmashala/src/features/companion/client/companion_gateway.dart';
import 'package:karmashala/src/features/companion/client/fake_companion_gateway.dart';
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
  });
}
