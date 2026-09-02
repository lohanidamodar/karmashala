import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/devices/data/scrcpy_control.dart';
import 'package:karmashala/src/features/devices/domain/device_keyboard.dart';

/// A key event built the way `HardwareKeyboard` would deliver it.
KeyDownEvent _down(LogicalKeyboardKey key, {String? character}) => KeyDownEvent(
  physicalKey: PhysicalKeyboardKey.keyA,
  logicalKey: key,
  character: character,
  timeStamp: Duration.zero,
);

KeyUpEvent _up(LogicalKeyboardKey key) => KeyUpEvent(
  physicalKey: PhysicalKeyboardKey.keyA,
  logicalKey: key,
  timeStamp: Duration.zero,
);

KeyRepeatEvent _repeat(LogicalKeyboardKey key, {String? character}) =>
    KeyRepeatEvent(
      physicalKey: PhysicalKeyboardKey.keyA,
      logicalKey: key,
      character: character,
      timeStamp: Duration.zero,
    );

const _plain = DesktopModifiers();
const _ctrl = DesktopModifiers(control: true);
const _shift = DesktopModifiers(shift: true);

void main() {
  group('DesktopModifiers → Android meta state', () {
    test('the generic bits are what KeyEvent.isCtrlPressed() reads', () {
      expect(_plain.androidMetaState, AndroidMetaState.none);
      expect(_ctrl.androidMetaState, AndroidMetaState.ctrlOn);
      expect(_shift.androidMetaState, AndroidMetaState.shiftOn);
      expect(
        const DesktopModifiers(
          control: true,
          shift: true,
        ).androidMetaState,
        AndroidMetaState.ctrlOn | AndroidMetaState.shiftOn,
      );
      expect(
        const DesktopModifiers(alt: true, meta: true).androidMetaState,
        AndroidMetaState.altOn | AndroidMetaState.metaOn,
      );
    });

    test('the lock keys are reported, because Android tracks them', () {
      expect(
        const DesktopModifiers(capsLock: true).androidMetaState,
        AndroidMetaState.capsLockOn,
      );
      expect(
        const DesktopModifiers(numLock: true).androidMetaState,
        AndroidMetaState.numLockOn,
      );
    });
  });

  group('DeviceKeyTranslator: printable text', () {
    test('a printable character becomes text, not a keycode', () {
      // The device's own layout decides which key produces "@"; sending
      // KEYCODE_2 with shift assumes it is the desktop's. scrcpy runs text
      // through the device's KeyCharacterMap instead.
      final translator = DeviceKeyTranslator();
      final intent = translator.translate(
        _down(LogicalKeyboardKey.digit2, character: '@'),
        const DesktopModifiers(shift: true),
      );
      expect(intent, isA<DeviceTextIntent>());
      expect((intent! as DeviceTextIntent).text, '@');
    });

    test('space is text, not KEYCODE_SPACE', () {
      final translator = DeviceKeyTranslator();
      final intent = translator.translate(
        _down(LogicalKeyboardKey.space, character: ' '),
        _plain,
      );
      expect((intent! as DeviceTextIntent).text, ' ');
    });

    test('the release of a text key sends nothing', () {
      // The character was already delivered on the way down. An ACTION_UP for
      // a keycode we never sent an ACTION_DOWN for is a stray event.
      final translator = DeviceKeyTranslator();
      translator.translate(
        _down(LogicalKeyboardKey.keyA, character: 'a'),
        _plain,
      );
      expect(translator.translate(_up(LogicalKeyboardKey.keyA), _plain), isNull);
    });

    test('holding a letter repeats the character', () {
      final translator = DeviceKeyTranslator();
      translator.translate(
        _down(LogicalKeyboardKey.keyA, character: 'a'),
        _plain,
      );
      final again = translator.translate(
        _repeat(LogicalKeyboardKey.keyA, character: 'a'),
        _plain,
      );
      expect((again! as DeviceTextIntent).text, 'a');
    });

    test('a control character is never sent as text', () {
      // Enter arrives with character "\n" on some platforms. Typing a newline
      // is not the same as pressing Enter: a search field submits on one and
      // ignores the other.
      final translator = DeviceKeyTranslator();
      final intent = translator.translate(
        _down(LogicalKeyboardKey.enter, character: '\n'),
        _plain,
      );
      expect(intent, isA<DeviceKeycodeIntent>());
      expect((intent! as DeviceKeycodeIntent).keyCode, AndroidKeyCode.enter);
    });
  });

  group('DeviceKeyTranslator: keycodes', () {
    test('a named key becomes the right keycode, down then up', () {
      final translator = DeviceKeyTranslator();
      final down =
          translator.translate(_down(LogicalKeyboardKey.backspace), _plain)!
              as DeviceKeycodeIntent;
      expect(down.keyCode, AndroidKeyCode.del);
      expect(down.action, AndroidKeyAction.down);
      expect(down.repeat, 0);
      expect(down.metaState, AndroidMetaState.none);

      final up =
          translator.translate(_up(LogicalKeyboardKey.backspace), _plain)!
              as DeviceKeycodeIntent;
      expect(up.keyCode, AndroidKeyCode.del);
      expect(up.action, AndroidKeyAction.up);
    });

    test('a modifier chord goes as a keycode, carrying its meta state', () {
      // Ctrl+A must select all on the device. As text it would type "a".
      final translator = DeviceKeyTranslator();
      final intent =
          translator.translate(
                _down(LogicalKeyboardKey.keyA, character: 'a'),
                _ctrl,
              )!
              as DeviceKeycodeIntent;
      expect(intent.keyCode, AndroidKeyCode.a);
      expect(intent.metaState, AndroidMetaState.ctrlOn);
    });

    test('holding backspace raises the repeat count Android expects', () {
      final translator = DeviceKeyTranslator();
      translator.translate(_down(LogicalKeyboardKey.backspace), _plain);
      final first =
          translator.translate(_repeat(LogicalKeyboardKey.backspace), _plain)!
              as DeviceKeycodeIntent;
      final second =
          translator.translate(_repeat(LogicalKeyboardKey.backspace), _plain)!
              as DeviceKeycodeIntent;
      expect(first.repeat, 1);
      expect(second.repeat, 2);
    });

    test('the arrows and editing keys all map', () {
      final translator = DeviceKeyTranslator();
      int codeFor(LogicalKeyboardKey key) =>
          (translator.translate(_down(key), _plain)! as DeviceKeycodeIntent)
              .keyCode;
      expect(codeFor(LogicalKeyboardKey.arrowUp), AndroidKeyCode.dpadUp);
      expect(codeFor(LogicalKeyboardKey.arrowDown), AndroidKeyCode.dpadDown);
      expect(codeFor(LogicalKeyboardKey.arrowLeft), AndroidKeyCode.dpadLeft);
      expect(codeFor(LogicalKeyboardKey.arrowRight), AndroidKeyCode.dpadRight);
      expect(codeFor(LogicalKeyboardKey.tab), AndroidKeyCode.tab);
      expect(codeFor(LogicalKeyboardKey.escape), AndroidKeyCode.escape);
      expect(codeFor(LogicalKeyboardKey.delete), AndroidKeyCode.forwardDel);
      expect(codeFor(LogicalKeyboardKey.home), AndroidKeyCode.moveHome);
      expect(codeFor(LogicalKeyboardKey.end), AndroidKeyCode.moveEnd);
      expect(codeFor(LogicalKeyboardKey.pageUp), AndroidKeyCode.pageUp);
      expect(codeFor(LogicalKeyboardKey.pageDown), AndroidKeyCode.pageDown);
    });

    test('a modifier key on its own is not forwarded', () {
      // Android tracks meta state per event; a lone Ctrl press means nothing
      // there and would only ever confuse a focused view.
      final translator = DeviceKeyTranslator();
      expect(
        translator.translate(_down(LogicalKeyboardKey.controlLeft), _plain),
        isNull,
      );
      expect(
        translator.translate(_down(LogicalKeyboardKey.shiftLeft), _plain),
        isNull,
      );
    });

    test('an unmapped key is reported rather than guessed at', () {
      final translator = DeviceKeyTranslator();
      expect(
        translator.translate(_down(LogicalKeyboardKey.f13), _plain),
        isNull,
      );
    });
  });

  group('DeviceKeyTranslator: releasing what is still held', () {
    test('losing focus lifts every key the device thinks is down', () {
      // Otherwise the phone is left with a key held forever — the arrow key
      // that scrolls to the bottom of a list on its own.
      final translator = DeviceKeyTranslator();
      translator.translate(_down(LogicalKeyboardKey.arrowDown), _plain);
      translator.translate(_down(LogicalKeyboardKey.shiftLeft), _shift);
      final released = translator.releaseAll();
      expect(released, hasLength(1));
      expect(released.single.action, AndroidKeyAction.up);
      expect(released.single.keyCode, AndroidKeyCode.dpadDown);
      // And the second call has nothing left to lift.
      expect(translator.releaseAll(), isEmpty);
    });
  });

  group('the escape chord', () {
    test('Ctrl+Alt+K is what turns forwarding off again', () {
      expect(kDeviceKeyboardEscape.trigger, LogicalKeyboardKey.keyK);
      expect(kDeviceKeyboardEscape.control, isTrue);
      expect(kDeviceKeyboardEscape.alt, isTrue);
      expect(kDeviceKeyboardEscapeLabel, 'Ctrl+Alt+K');
    });

    test('it is never translated, so it can never reach the device', () {
      // The whole point: a user who turns forwarding on must not be able to
      // lose the one chord that turns it off.
      final translator = DeviceKeyTranslator();
      expect(
        translator.translate(
          _down(LogicalKeyboardKey.keyK, character: 'k'),
          const DesktopModifiers(control: true, alt: true),
        ),
        isNull,
      );
      expect(
        translator.translate(
          _up(LogicalKeyboardKey.keyK),
          const DesktopModifiers(control: true, alt: true),
        ),
        isNull,
      );
    });

    test('Ctrl+K without Alt still reaches the device', () {
      // Karmashala's own Ctrl+K is exactly the shortcut the owner wants the
      // phone to receive while forwarding is on.
      final translator = DeviceKeyTranslator();
      final intent = translator.translate(
        _down(LogicalKeyboardKey.keyK, character: 'k'),
        _ctrl,
      );
      expect((intent! as DeviceKeycodeIntent).keyCode, AndroidKeyCode.k);
    });
  });

  group('intents on the wire', () {
    test('a keycode intent encodes as INJECT_KEYCODE', () {
      const intent = DeviceKeycodeIntent(
        action: AndroidKeyAction.down,
        keyCode: AndroidKeyCode.del,
        repeat: 2,
        metaState: AndroidMetaState.ctrlOn,
      );
      final bytes = ScrcpyKeycodeEvent(
        action: intent.action,
        keyCode: intent.keyCode,
        repeat: intent.repeat,
        metaState: intent.metaState,
      ).encode();
      expect(bytes.length, kScrcpyKeycodeMessageLength);
      expect(bytes.first, ScrcpyControlType.injectKeycode);
    });
  });
}
