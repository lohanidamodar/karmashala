import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_devices/devices.dart';
import 'package:karmashala_devices/widgets.dart';

class _RecordingSink implements DeviceKeyboardSink {
  _RecordingSink({
    this.transport = DeviceKeyboardTransport.scrcpyControl,
    this.refuseWith,
  });

  final List<DeviceKeyIntent> sent = [];

  /// When set, every keycode is refused with this reason — a sink that knows
  /// something more specific than its transport's blanket limitation.
  final String? refuseWith;

  @override
  final DeviceKeyboardTransport transport;

  @override
  String? refusal;

  @override
  bool send(DeviceKeyIntent intent) {
    if (refuseWith != null && intent is DeviceKeycodeIntent) {
      refusal = refuseWith;
      return false;
    }
    sent.add(intent);
    refusal = null;
    return true;
  }

  List<String> get text => [
    for (final intent in sent)
      if (intent is DeviceTextIntent) intent.text,
  ];

  List<int> get keyCodes => [
    for (final intent in sent)
      if (intent is DeviceKeycodeIntent) intent.keyCode,
  ];
}

void main() {
  late _RecordingSink sink;

  setUp(() => sink = _RecordingSink());

  /// The surface plus a sibling that can steal focus, so "the pane is not
  /// focused" is a real state rather than a flag.
  Future<FocusNode> pump(
    WidgetTester tester, {
    DeviceKeyboardSink? keyboard,
    bool useSink = true,
  }) async {
    final elsewhere = FocusNode(debugLabel: 'elsewhere');
    addTearDown(elsewhere.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Focus(focusNode: elsewhere, child: const SizedBox(height: 20)),
              Expanded(
                child: DeviceKeyboardSurface(
                  sink: useSink ? (keyboard ?? sink) : null,
                  deviceLabel: 'CPH1989',
                  child: const SizedBox.expand(
                    child: ColoredBox(color: Color(0xFF000000)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return elsewhere;
  }

  Future<void> focusSurface(WidgetTester tester) async {
    await tester.tap(find.byType(DeviceKeyboardSurface));
    await tester.pump();
    await tester.pump();
  }

  /// Ctrl+Alt+K, pressed as a real chord.
  Future<void> pressEscapeChord(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  group('focus is the switch', () {
    testWidgets('clicking the picture starts forwarding, with no other act', (
      tester,
    ) async {
      // The owner reached for the pane expecting to type into it and nothing
      // happened, because forwarding used to need arming first. One click is
      // now the whole gesture.
      await pump(tester);
      await focusSurface(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
      await tester.pump();

      expect(sink.text, ['h', 'i']);
      expect(find.text(kKeyboardOnLabel), findsOneWidget);
    });

    testWidgets('an unfocused pane forwards nothing and says so', (
      tester,
    ) async {
      // Never armed by merely existing: a mirror sitting in a pane the user is
      // not looking at must not see the keystrokes meant for the terminal.
      await pump(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pump();

      expect(sink.sent, isEmpty);
      expect(find.text(kKeyboardOffLabel), findsOneWidget);
      expect(find.text(kKeyboardOnLabel), findsNothing);
    });

    testWidgets('and named keys go as keycodes once focused', (tester) async {
      await pump(tester);
      await focusSurface(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();

      expect(sink.keyCodes, [AndroidKeyCode.del, AndroidKeyCode.del]);
    });

    testWidgets('losing focus stops forwarding again', (tester) async {
      final elsewhere = await pump(tester);
      await focusSurface(tester);
      elsewhere.requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pump();

      expect(sink.sent, isEmpty);
    });

    testWidgets('losing focus lifts a key that was still held', (tester) async {
      final elsewhere = await pump(tester);
      await focusSurface(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(sink.keyCodes, [AndroidKeyCode.dpadDown]);

      elsewhere.requestFocus();
      await tester.pump();

      expect(sink.keyCodes, [AndroidKeyCode.dpadDown, AndroidKeyCode.dpadDown]);
      expect(
        (sink.sent.last as DeviceKeycodeIntent).action,
        AndroidKeyAction.up,
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    });

    testWidgets('the desktop\'s own shortcuts stop reaching the app', (
      tester,
    ) async {
      // This is the whole reason there is a way to stop: Ctrl+W must close a
      // tab on the phone, not in Karmashala.
      var appSawIt = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Shortcuts(
            shortcuts: <ShortcutActivator, Intent>{
              const SingleActivator(LogicalKeyboardKey.keyW, control: true):
                  VoidCallbackIntent(() => appSawIt = true),
            },
            child: Actions(
              actions: <Type, Action<Intent>>{
                VoidCallbackIntent: VoidCallbackAction(),
              },
              child: Scaffold(
                body: DeviceKeyboardSurface(
                  sink: sink,
                  deviceLabel: 'CPH1989',
                  child: const SizedBox.expand(
                    child: ColoredBox(color: Color(0xFF000000)),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await focusSurface(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(appSawIt, isFalse);
      expect(sink.keyCodes, contains(AndroidKeyCode.w));
    });
  });

  group('nothing else may take the keyboard away', () {
    testWidgets('an armed, focused pane marks itself as holding the keyboard', (
      tester,
    ) async {
      // The terminal controller re-requests its pane's focus after a frame and
      // used to guard only on "is this an EditableText", which a mirror is not
      // — so it took the keyboard back and the next keystroke was typed into
      // the shell. `keyboardIsSpokenFor` is the shared rule that stops it.
      await pump(tester);
      expect(keyboardIsSpokenFor(), isFalse);

      await focusSurface(tester);
      expect(keyboardIsSpokenFor(), isTrue);
      expect(find.byType(KeyboardCaptureScope), findsOneWidget);
    });

    testWidgets('a pane that is not forwarding makes no such claim', (
      tester,
    ) async {
      // Otherwise a mirror that is only being looked at would pin the keyboard
      // away from the terminal for no reason.
      await pump(tester);
      await focusSurface(tester);
      await pressEscapeChord(tester);

      expect(keyboardIsSpokenFor(), isFalse);
      expect(find.byType(KeyboardCaptureScope), findsNothing);
    });

    testWidgets('and a pane with no transport never claims it', (tester) async {
      await pump(tester, useSink: false);
      await focusSurface(tester);

      expect(keyboardIsSpokenFor(), isFalse);
    });
  });

  group('the escape chord', () {
    testWidgets('Ctrl+Alt+K stops forwarding and is never forwarded', (
      tester,
    ) async {
      await pump(tester);
      await focusSurface(tester);
      await pressEscapeChord(tester);

      expect(sink.sent, isEmpty);
      expect(find.text(kKeyboardOffLabel), findsOneWidget);

      // And the pane really is quiet afterwards, not merely relabelled.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pump();
      expect(sink.sent, isEmpty);
    });

    testWidgets('and turns it back on from off', (tester) async {
      await pump(tester);
      await focusSurface(tester);
      await pressEscapeChord(tester);
      await pressEscapeChord(tester);

      expect(find.text(kKeyboardOnLabel), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pump();
      expect(sink.text, ['a']);
    });

    testWidgets('a suspended pane stays suspended across a focus round trip', (
      tester,
    ) async {
      // Someone who turned forwarding off, looked away and looked back has not
      // asked for it again. Re-arming on focus would make the off switch a
      // thing that undoes itself.
      final elsewhere = await pump(tester);
      await focusSurface(tester);
      await pressEscapeChord(tester);

      elsewhere.requestFocus();
      await tester.pump();
      await focusSurface(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pump();
      expect(sink.sent, isEmpty);
    });

    testWidgets('the way out is written where the user can see it', (
      tester,
    ) async {
      await pump(tester);
      await focusSurface(tester);
      expect(
        find.textContaining(kDeviceKeyboardEscapeLabel),
        findsAtLeastNWidgets(1),
      );
    });
  });

  group('degrading honestly', () {
    testWidgets('no input transport at all says so and cannot be armed', (
      tester,
    ) async {
      await pump(tester, useSink: false);
      expect(find.text(kKeyboardUnavailableLabel), findsOneWidget);
      final toggle = tester.widget<Switch>(find.byType(Switch));
      expect(toggle.onChanged, isNull);
    });

    testWidgets('no keystroke is silently swallowed when there is no sink', (
      tester,
    ) async {
      // Nothing to assert on the wire; what matters is that the pane does not
      // eat the key either — it goes back to the app rather than nowhere.
      await pump(tester, useSink: false);
      await focusSurface(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pump();
      expect(sink.sent, isEmpty);
    });

    testWidgets('a refused key is reported in the sink\'s own words', (
      tester,
    ) async {
      // The transport's `limitation` is one blanket sentence about chords. A
      // sink that refused Page Down because iOS has no such key knows better,
      // and telling the user about a modifier problem they do not have sends
      // them looking in the wrong place.
      const reason = 'iOS has no Page Down key';
      await pump(
        tester,
        keyboard: _RecordingSink(
          transport: DeviceKeyboardTransport.webDriverAgent,
          refuseWith: reason,
        ),
      );
      await focusSurface(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pump();

      expect(find.text(reason), findsOneWidget);
      expect(
        find.textContaining(DeviceKeyboardTransport.webDriverAgent.limitation!),
        findsNothing,
      );
    });

    testWidgets('the adb fallback says what it cannot do', (tester) async {
      await pump(
        tester,
        keyboard: _RecordingSink(transport: DeviceKeyboardTransport.adbInput),
      );
      await focusSurface(tester);
      expect(
        find.textContaining(DeviceKeyboardTransport.adbInput.limitation!),
        findsOneWidget,
      );
    });
  });
}
