import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:karmashala_devices/src/data/scrcpy_control.dart';
import 'package:karmashala_devices/src/data/scrcpy_device_message.dart';

/// The expected encodings, spelled out independently of the implementation.
///
/// Every offset below comes from disassembling `assets/scrcpy/scrcpy-server`
/// (scrcpy 7.27) with `dexdump -d`:
///
/// * `ControlMessage.TYPE_GET_CLIPBOARD` = 8, `TYPE_SET_CLIPBOARD` = 9.
/// * `ControlMessageReader.parseGetClipboard`: one `readUnsignedByte`.
/// * `ControlMessageReader.parseSetClipboard`: `readLong`, `readByte`,
///   `parseString()` — which is `parseString(4)`, a four-byte length.
/// * `DeviceMessage.TYPE_CLIPBOARD` = 0, `TYPE_ACK_CLIPBOARD` = 1,
///   `TYPE_UHID_OUTPUT` = 2.
/// * `DeviceMessageWriter.write`: `writeByte(type)`, then for the clipboard a
///   `writeInt` length and the bytes; for the ack a `writeLong`; for UHID two
///   `writeShort`s and the bytes.
///
/// A field in the wrong place does not fail loudly. The server reads a
/// plausible value out of the wrong bytes, applies it, and the socket carries
/// on — which is why these assert on the bytes rather than on a round trip
/// through our own parser.
int _u8(Uint8List b, int i) => ByteData.sublistView(b).getUint8(i);
int _u32(Uint8List b, int i) => ByteData.sublistView(b).getUint32(i);
int _i64(Uint8List b, int i) => ByteData.sublistView(b).getInt64(i);

Uint8List _deviceClipboard(String text) {
  final payload = utf8.encode(text);
  final bytes = Uint8List(5 + payload.length);
  ByteData.sublistView(bytes)
    ..setUint8(0, ScrcpyDeviceMessageType.clipboard)
    ..setUint32(1, payload.length);
  bytes.setRange(5, bytes.length, payload);
  return bytes;
}

Uint8List _deviceAck(int sequence) {
  final bytes = Uint8List(9);
  ByteData.sublistView(bytes)
    ..setUint8(0, ScrcpyDeviceMessageType.ackClipboard)
    ..setInt64(1, sequence);
  return bytes;
}

void main() {
  group('GET_CLIPBOARD', () {
    test('is exactly two bytes — the type and the copy key', () {
      // parseGetClipboard consumes one byte after the type. A third would be
      // read as the *next* message's type and the socket never recovers.
      final bytes = encodeGetClipboard();
      expect(bytes.length, 2);
      expect(_u8(bytes, 0), 8);
      expect(_u8(bytes, 1), ScrcpyCopyKey.none);
    });

    test('defaults to COPY_KEY_NONE rather than pressing Ctrl+C', () {
      // COPY_KEY_COPY injects a real Ctrl+C into whatever app is in front.
      // Asking "what is on the clipboard" must not edit the user's document.
      expect(_u8(encodeGetClipboard(), 1), 0);
      expect(_u8(encodeGetClipboard(copyKey: ScrcpyCopyKey.copy), 1), 1);
      expect(_u8(encodeGetClipboard(copyKey: ScrcpyCopyKey.cut), 1), 2);
    });
  });

  group('SET_CLIPBOARD', () {
    test('lays out type, sequence, paste flag and a four-byte length', () {
      const message = ScrcpySetClipboardMessage(sequence: 7, text: 'hello');
      final bytes = message.encode();
      expect(bytes.length, 14 + 5);
      expect(_u8(bytes, 0), 9);
      expect(_i64(bytes, 1), 7);
      expect(_u8(bytes, 9), 0);
      expect(_u32(bytes, 10), 5);
      expect(utf8.decode(bytes.sublist(14)), 'hello');
    });

    test('the length counts UTF-8 bytes, not characters', () {
      // The device's own filenames and text are UTF-8; a length in characters
      // makes the server readFully fewer bytes than were sent and then read
      // the tail as the next message.
      const message = ScrcpySetClipboardMessage(
        sequence: 1,
        text: 'नेपाली',
      );
      final bytes = message.encode();
      expect(_u32(bytes, 10), utf8.encode('नेपाली').length);
      expect(_u32(bytes, 10), greaterThan('नेपाली'.length));
      expect(utf8.decode(bytes.sublist(14)), 'नेपाली');
    });

    test('paste is off by default and is a real byte when asked for', () {
      expect(_u8(const ScrcpySetClipboardMessage(sequence: 1, text: 'a').encode(), 9), 0);
      expect(
        _u8(
          const ScrcpySetClipboardMessage(
            sequence: 1,
            text: 'a',
            paste: true,
          ).encode(),
          9,
        ),
        1,
      );
    });

    test('empty text is a legal message — clearing is a thing to do', () {
      final bytes = const ScrcpySetClipboardMessage(
        sequence: 3,
        text: '',
      ).encode();
      expect(bytes.length, 14);
      expect(_u32(bytes, 10), 0);
    });

    test('refuses text over the reader limit instead of truncating it', () {
      // ControlMessageReader.CLIPBOARD_TEXT_MAX_LENGTH is 262130. The server
      // refuses a longer message and the socket then desynchronises, so a
      // truncating encoder would trade a visible error for a dead socket.
      final tooLong = 'x' * (kScrcpyClipboardTextMaxBytes + 1);
      expect(
        () => ScrcpySetClipboardMessage(sequence: 1, text: tooLong).encode(),
        throwsArgumentError,
      );
      expect(
        ScrcpySetClipboardMessage(
          sequence: 1,
          text: 'x' * kScrcpyClipboardTextMaxBytes,
        ).encode().length,
        14 + kScrcpyClipboardTextMaxBytes,
      );
    });

    test('the inbound and outbound limits are different numbers', () {
      // Two constants in the jar, nine bytes apart. Collapsing them to one
      // would refuse a clipboard the device is entitled to send.
      expect(kScrcpyClipboardTextMaxBytes, 262130);
      expect(kScrcpyDeviceClipboardMaxBytes, 262139);
    });
  });

  group('ScrcpyDeviceMessageParser', () {
    test('reads a clipboard message', () {
      final parser = ScrcpyDeviceMessageParser();
      final messages = parser.add(_deviceClipboard('copied on the phone'));
      expect(messages, hasLength(1));
      expect(
        (messages.single as ScrcpyClipboardText).text,
        'copied on the phone',
      );
    });

    test('keeps trailing whitespace, which is part of what was copied', () {
      final parser = ScrcpyDeviceMessageParser();
      final messages = parser.add(_deviceClipboard('  spaced  \n'));
      expect((messages.single as ScrcpyClipboardText).text, '  spaced  \n');
    });

    test('reassembles a message split across chunks', () {
      // A 256 KB clipboard arrives in dozens of TCP pieces; a parser that
      // needed whole messages would produce nothing at all.
      final whole = _deviceClipboard('split me up');
      final parser = ScrcpyDeviceMessageParser();
      for (var i = 0; i < whole.length - 1; i++) {
        expect(parser.add([whole[i]]), isEmpty, reason: 'byte $i');
      }
      final messages = parser.add([whole.last]);
      expect((messages.single as ScrcpyClipboardText).text, 'split me up');
    });

    test('reads two messages out of one chunk', () {
      final parser = ScrcpyDeviceMessageParser();
      final messages = parser.add([
        ..._deviceAck(11),
        ..._deviceClipboard('after'),
      ]);
      expect(messages, hasLength(2));
      expect((messages.first as ScrcpyClipboardAck).sequence, 11);
      expect((messages.last as ScrcpyClipboardText).text, 'after');
    });

    test('reads the ack sequence as a full 64-bit value', () {
      final parser = ScrcpyDeviceMessageParser();
      final messages = parser.add(_deviceAck(0x0102030405060708));
      expect(
        (messages.single as ScrcpyClipboardAck).sequence,
        0x0102030405060708,
      );
    });

    test('steps over a UHID output message', () {
      // Nothing creates a UHID device yet. The point is measurable *length*:
      // a message that cannot be measured cannot be stepped over, and the next
      // one would be read out of the middle of it.
      final uhid = Uint8List.fromList([
        ScrcpyDeviceMessageType.uhidOutput,
        0x00, 0x02, // id
        0x00, 0x03, // size
        0xAA, 0xBB, 0xCC,
      ]);
      final parser = ScrcpyDeviceMessageParser();
      final messages = parser.add([...uhid, ..._deviceAck(4)]);
      expect(messages, hasLength(2));
      final output = messages.first as ScrcpyUhidOutput;
      expect(output.id, 2);
      expect(output.data, [0xAA, 0xBB, 0xCC]);
      expect((messages.last as ScrcpyClipboardAck).sequence, 4);
    });

    test('an unknown type stops the parse rather than guessing a length', () {
      final parser = ScrcpyDeviceMessageParser();
      final messages = parser.add([9, 1, 2, 3]);
      expect(messages.single, isA<ScrcpyUnknownDeviceMessage>());
      expect((messages.single as ScrcpyUnknownDeviceMessage).type, 9);
      expect(parser.desynchronised, isTrue);
      // And nothing after it is invented.
      expect(parser.add(_deviceAck(1)), isEmpty);
    });

    test('a clipboard length is four bytes, not two', () {
      // The one asymmetry with UHID, and the one that silently truncates: a
      // 70 000-byte clipboard read as a short is 4464 bytes and the rest
      // becomes the next "message".
      final parser = ScrcpyDeviceMessageParser();
      final text = 'y' * 70000;
      final messages = parser.add(_deviceClipboard(text));
      expect((messages.single as ScrcpyClipboardText).text.length, 70000);
      expect(parser.desynchronised, isFalse);
    });
  });
}
