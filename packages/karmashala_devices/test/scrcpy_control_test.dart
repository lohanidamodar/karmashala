import 'dart:convert';
import 'dart:typed_data';

import 'package:karmashala_devices/src/data/scrcpy_control.dart';
import 'package:karmashala_devices/src/domain/device_keyboard.dart';
import 'package:test/test.dart';

/// The expected encoding, spelled out independently of the implementation, from
/// disassembling the scrcpy-server jar this app deploys. A field in the wrong
/// place does not fail loudly: the touch lands somewhere else, or vanishes.
int _u8(Uint8List b, int i) => ByteData.sublistView(b).getUint8(i);
int _u16(Uint8List b, int i) => ByteData.sublistView(b).getUint16(i);
int _i32(Uint8List b, int i) => ByteData.sublistView(b).getInt32(i);
int _u64(Uint8List b, int i) => ByteData.sublistView(b).getUint64(i);

void main() {
  _keyboardWire();

  group('encodePressure', () {
    test('1.0 is 0xFFFF exactly, not 0x10000 truncated', () {
      // `Binary.u16FixedPointToFloat` special-cases 0xFFFF as 1.0 and divides
      // everything else by 0x10000, so the top of the range is not linear.
      expect(encodePressure(1.0), 0xFFFF);
    });

    test('0.0 is zero, which is what a release reports', () {
      expect(encodePressure(0.0), 0);
    });

    test('a middling pressure round-trips through the fixed point', () {
      expect(encodePressure(0.5), 0x8000);
      expect(0x8000 / 0x10000, 0.5);
    });

    test('out-of-range values are clamped rather than wrapped', () {
      expect(encodePressure(3.5), 0xFFFF);
      expect(encodePressure(-1), 0);
      expect(encodePressure(double.nan), 0);
    });
  });

  group('INJECT_TOUCH_EVENT', () {
    const event = ScrcpyTouchEvent(
      action: AndroidMotionAction.move,
      pointerId: 3,
      x: 200,
      y: 900,
      videoWidth: 472,
      videoHeight: 1024,
      pressure: 1.0,
    );

    test('is exactly 32 bytes', () {
      expect(event.encode().length, kScrcpyTouchMessageLength);
      expect(kScrcpyTouchMessageLength, 32);
    });

    test('lays every field at the offset the server reads it from', () {
      final bytes = event.encode();
      expect(_u8(bytes, 0), 2, reason: 'TYPE_INJECT_TOUCH_EVENT');
      expect(_u8(bytes, 1), AndroidMotionAction.move);
      expect(_u64(bytes, 2), 3, reason: 'pointer id is a long');
      expect(_i32(bytes, 10), 200);
      expect(_i32(bytes, 14), 900);
      expect(_u16(bytes, 18), 472);
      expect(_u16(bytes, 20), 1024);
      expect(_u16(bytes, 22), 0xFFFF);
      expect(_i32(bytes, 24), 0, reason: 'action button');
      expect(_i32(bytes, 28), 0, reason: 'buttons');
    });

    test('leaves the buttons clear so the event is a finger, not a mouse', () {
      // `Controller.injectTouch` picks SOURCE_MOUSE when any non-primary button
      // is set, and a mouse source produces no fling velocity.
      final bytes = event.encode();
      expect(_i32(bytes, 24), 0);
      expect(_i32(bytes, 28), 0);
    });

    test('the four actions are the AOSP MotionEvent values', () {
      expect(AndroidMotionAction.down, 0);
      expect(AndroidMotionAction.up, 1);
      expect(AndroidMotionAction.move, 2);
      expect(AndroidMotionAction.cancel, 3);
    });

    test('the message type ids match the server switch', () {
      expect(ScrcpyControlType.injectKeycode, 0);
      expect(ScrcpyControlType.injectText, 1);
      expect(ScrcpyControlType.injectTouchEvent, 2);
      expect(ScrcpyControlType.injectScrollEvent, 3);
      expect(ScrcpyControlType.backOrScreenOn, 4);
    });

    test('a negative coordinate survives as a signed int', () {
      // A pointer dragged past the edge legitimately reports one, and reading
      // it as unsigned would put the touch two billion pixels away.
      final bytes = const ScrcpyTouchEvent(
        action: AndroidMotionAction.move,
        pointerId: 0,
        x: -5,
        y: -1,
        videoWidth: 100,
        videoHeight: 200,
      ).encode();
      expect(_i32(bytes, 10), -5);
      expect(_i32(bytes, 14), -1);
    });

    test('distinct pointer ids are what make multi-touch work', () {
      // The server derives ACTION_POINTER_DOWN/UP and the pointer index itself
      // from its PointersState; the client only ever varies this field.
      final a = const ScrcpyTouchEvent(
        action: AndroidMotionAction.down,
        pointerId: 0,
        x: 1,
        y: 1,
        videoWidth: 10,
        videoHeight: 10,
      ).encode();
      final b = const ScrcpyTouchEvent(
        action: AndroidMotionAction.down,
        pointerId: 1,
        x: 1,
        y: 1,
        videoWidth: 10,
        videoHeight: 10,
      ).encode();
      expect(_u8(a, 1), _u8(b, 1), reason: 'both are a plain ACTION_DOWN');
      expect(_u64(a, 2), 0);
      expect(_u64(b, 2), 1);
    });

    test('the ids scrcpy reserves are documented so we can avoid them', () {
      expect(ScrcpyPointerId.mouse, -1);
      expect(ScrcpyPointerId.genericFinger, -2);
      expect(ScrcpyPointerId.virtualMouse, -3);
      expect(ScrcpyPointerId.virtualFinger, -4);
    });
  });
}

/// The keyboard half of the same protocol, read out of the same jar:
/// `parseInjectKeycode` reads an unsigned byte then three ints, and
/// `parseInjectText` a **four**-byte length capped at 300.
void _keyboardWire() {
  group('INJECT_KEYCODE', () {
    const event = ScrcpyKeycodeEvent(
      action: AndroidKeyAction.down,
      keyCode: AndroidKeyCode.enter,
      repeat: 0,
      metaState: AndroidMetaState.shiftOn,
    );

    test('is exactly 14 bytes', () {
      expect(event.encode().length, kScrcpyKeycodeMessageLength);
      expect(kScrcpyKeycodeMessageLength, 14);
    });

    test('lays every field at the offset the server reads it from', () {
      final bytes = event.encode();
      expect(_u8(bytes, 0), ScrcpyControlType.injectKeycode);
      expect(_u8(bytes, 1), AndroidKeyAction.down);
      expect(_i32(bytes, 2), AndroidKeyCode.enter);
      expect(_i32(bytes, 6), 0);
      expect(_i32(bytes, 10), AndroidMetaState.shiftOn);
    });

    test('an auto-repeat carries the repeat count Android expects', () {
      const held = ScrcpyKeycodeEvent(
        action: AndroidKeyAction.down,
        keyCode: AndroidKeyCode.del,
        repeat: 7,
      );
      final bytes = held.encode();
      expect(_i32(bytes, 6), 7);
      expect(_i32(bytes, 10), AndroidMetaState.none);
    });

    test('the two key actions are the AOSP KeyEvent values', () {
      expect(AndroidKeyAction.down, 0);
      expect(AndroidKeyAction.up, 1);
    });
  });

  group('INJECT_TEXT', () {
    test('is a four-byte big-endian length then UTF-8', () {
      final bytes = const ScrcpyTextEvent('hi').encode();
      expect(_u8(bytes, 0), ScrcpyControlType.injectText);
      expect(ByteData.sublistView(bytes).getUint32(1), 2);
      expect(bytes.sublist(5), [0x68, 0x69]);
      expect(bytes.length, 7);
    });

    test('the length counts bytes, not characters', () {
      // 'é' is two bytes in UTF-8. Counting characters would make the server
      // read one byte short and then misparse the *next* message.
      final bytes = const ScrcpyTextEvent('é').encode();
      expect(ByteData.sublistView(bytes).getUint32(1), 2);
      expect(bytes.length, 7);
    });

    test('an empty string is refused rather than sent as a no-op', () {
      expect(const ScrcpyTextEvent('').encode, throwsArgumentError);
    });

    test('text is split so no message exceeds the server cap', () {
      // The server allocates the declared length and `readFully`s it; over the
      // cap scrcpy 4.1 refuses the message, so a long paste arrives as several.
      expect(kScrcpyInjectTextMaxBytes, 300);
      final chunks = splitForInjectText('a' * 701);
      expect(chunks.length, 3);
      expect(chunks.first.length, kScrcpyInjectTextMaxBytes);
      expect(chunks.join(), 'a' * 701);
    });

    test('a split never lands in the middle of a character', () {
      // Two-byte 'é' 200 times = 400 bytes. A naive cut at byte 300 would
      // halve one, and the server would decode a replacement character.
      final chunks = splitForInjectText('é' * 200);
      expect(chunks.length, 2);
      for (final chunk in chunks) {
        expect(
          utf8.encode(chunk).length,
          lessThanOrEqualTo(kScrcpyInjectTextMaxBytes),
        );
        expect(chunk.contains('�'), isFalse);
      }
      expect(chunks.join(), 'é' * 200);
    });
  });

  group('RESET_VIDEO', () {
    test('is type 17, read out of the jar this app deploys', () {
      // Not from documentation: the numbering has moved between scrcpy
      // releases, and a wrong byte here is a *valid* message meaning something
      // else.
      expect(ScrcpyControlType.resetVideo, 17);
    });

    test('is exactly one byte', () {
      // Key 17 routes to `createEmpty(type)`. Anything sent after the type byte
      // would be read as the next message's type and desynchronise the socket.
      expect(encodeResetVideo(), [17]);
    });
  });
}
