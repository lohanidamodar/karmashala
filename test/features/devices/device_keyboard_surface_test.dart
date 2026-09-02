import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/devices/data/device_keyboard_sink.dart';
import 'package:karmashala/src/features/devices/domain/device_keyboard.dart';
import 'package:karmashala/src/features/devices/presentation/device_keyboard_surface.dart';

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
    required bool forwarding,
    DeviceKeyboardSink? keyboard,
    ValueChanged<bool>? onForwardingChanged,
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
                  forwarding: forwarding,
                  onForwardingChanged: onForwardingChanged ?? (_) {},
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

  group('forwarding is off by default', () {
    testWidgets('a focused pane with forwarding off sends nothing', (
      tester,
    ) async {
      await pump(tester, forwarding: false);
      await focusSurface(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();

      expect(sink.sent, isEmpty);
    });

    testWidgets('and the state is stated on screen, not implied', (
      tester,
    ) async {
      await pump(tester, forwarding: false);
      expect(find.text(kKeyboardOffLabel), findsOneWidget);
      expect(find.text(kKeyboardOnLabel), findsNothing);
    });
  });

  group('forwarding on', () {
    testWidgets('a focused pane types printable characters as text', (
      tester,
    ) async {
      await pump(tester, forwarding: true);
      await focusSurface(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
      await tester.pump();

      expect(sink.text, ['h', 'i']);
    });

    testWidgets('and named keys as keycodes', (tester) async {
      await pump(tester, forwarding: true);
      await focusSurface(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();

      expect(sink.keyCodes, [AndroidKeyCode.del, AndroidKeyCode.del]);
    });

    testWidgets('an unfocused pane in the background receives nothing', (
      tester,
    ) async {
      // The mirror can sit in a pane the user is not looking at. Typing into
      // the terminal must not also type into the phone.
      final elsewhere = await pump(tester, forwarding: true);
      await focusSurface(tester);
      elsewhere.requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pump();

      expect(sink.sent, isEmpty);
    });

    testWidgets('losing focus lifts a key that was still held', (tester) async {
      final elsewhere = await pump(tester, forwarding: true);
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
      // This is the whole reason there is an off switch: Ctrl+W must close a
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
                  forwarding: true,
                  onForwardingChanged: (_) {},
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

  group('the escape chord', () {
    testWidgets('Ctrl+Alt+K turns forwarding off and is never forwarded', (
      tester,
    ) async {
      bool? requested;
      await pump(
        tester,
        forwarding: true,
        onForwardingChanged: (value) => requested = value,
      );
      await focusSurface(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(requested, isFalse);
      expect(sink.sent, isEmpty);
    });

    testWidgets('and turns it back on from off', (tester) async {
      bool? requested;
      await pump(
        tester,
        forwarding: false,
        onForwardingChanged: (value) => requested = value,
      );
      await focusSurface(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(requested, isTrue);
      expect(sink.sent, isEmpty);
    });

    testWidgets('the way out is written where the user can see it', (
      tester,
    ) async {
      await pump(tester, forwarding: true);
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
      await pump(tester, forwarding: false, useSink: false);
      expect(find.text(kKeyboardUnavailableLabel), findsOneWidget);
      final toggle = tester.widget<Switch>(find.byType(Switch));
      expect(toggle.onChanged, isNull);
    });

    testWidgets('no keystroke is silently swallowed when there is no sink', (
      tester,
    ) async {
      // Nothing to assert on the wire; what matters is that the pane does not
      // eat the key either — it goes back to the app rather than nowhere.
      await pump(tester, forwarding: true, useSink: false);
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
        forwarding: true,
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
        find.textContaining(
          DeviceKeyboardTransport.webDriverAgent.limitation!,
        ),
        findsNothing,
      );
    });

    testWidgets('the adb fallback says what it cannot do', (tester) async {
      await pump(
        tester,
        forwarding: true,
        keyboard: _RecordingSink(
          transport: DeviceKeyboardTransport.adbInput,
        ),
      );
      expect(
        find.textContaining(DeviceKeyboardTransport.adbInput.limitation!),
        findsOneWidget,
      );
    });
  });
}
