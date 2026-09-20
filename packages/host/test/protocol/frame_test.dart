import 'dart:typed_data';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

Uint8List body(int length, [int fill = 0x41]) =>
    Uint8List(length)..fillRange(0, length, fill);

void main() {
  group('Frame', () {
    test('the header is eight bytes: type, flags, ref, length', () {
      final encoded = Frame(MessageType.output, 0x0102, body(3)).encode();
      expect(encoded, hasLength(11));
      expect(encoded[0], MessageType.output.code);
      expect(encoded[1], 0);
      expect(encoded[2], 0x01);
      expect(encoded[3], 0x02);
      expect(encoded.sublist(4, 8), [0, 0, 0, 3]);
    });

    test('message type codes are part of the protocol and must not drift', () {
      expect(MessageType.hello.code, 0x01);
      expect(MessageType.output.code, 0x08);
      expect(MessageType.error.code, 0x11);
      expect(
        MessageType.values.map((t) => t.code).toSet(),
        hasLength(MessageType.values.length),
      );
    });
  });

  group('FrameParser', () {
    test('reassembles a frame split across every possible boundary', () {
      final source = Frame(MessageType.input, 7, body(20)).encode();
      for (var cut = 1; cut < source.length; cut++) {
        final parser = FrameParser();
        expect(
          parser.add(source.sublist(0, cut)),
          isEmpty,
          reason: 'cut at $cut',
        );
        final frames = parser.add(source.sublist(cut));
        expect(frames, hasLength(1), reason: 'cut at $cut');
        expect(frames.single.payload, hasLength(20));
      }
    });

    test('yields several frames from one chunk, in order', () {
      final chunk = <int>[
        ...Frame(MessageType.hello, 0, body(1, 1)).encode(),
        ...Frame(MessageType.input, 2, body(2, 2)).encode(),
        ...Frame(MessageType.resize, 3, body(4, 3)).encode(),
      ];
      final frames = FrameParser().add(chunk);
      expect(frames.map((f) => f.type), [
        MessageType.hello,
        MessageType.input,
        MessageType.resize,
      ]);
      expect(frames[1].sessionRef, 2);
      expect(frames[2].payload, hasLength(4));
    });

    test('keeps a partial frame across chunks and finishes it later', () {
      final parser = FrameParser();
      final first = Frame(MessageType.output, 1, body(10)).encode();
      expect(parser.add(first.sublist(0, 5)), isEmpty);
      expect(parser.add(first.sublist(5, 12)), isEmpty);
      expect(parser.add(first.sublist(12)), hasLength(1));
      expect(parser.add(const []), isEmpty);
    });

    test('an empty payload is a legal frame', () {
      final frames = FrameParser().add(
        Frame(MessageType.list, 0, Uint8List(0)).encode(),
      );
      expect(frames.single.payload, isEmpty);
    });

    test(
      'an unknown type is refused rather than resynchronised onto garbage',
      () {
        final bad = Uint8List.fromList([0x7f, 0, 0, 0, 0, 0, 0, 0]);
        expect(
          () => FrameParser().add(bad),
          throwsA(isA<FrameFormatException>()),
        );
      },
    );

    test('an absurd length is refused before anything is allocated', () {
      final bad = Uint8List.fromList([
        MessageType.output.code,
        0,
        0,
        1,
        0xff,
        0xff,
        0xff,
        0xff,
      ]);
      expect(
        () => FrameParser().add(bad),
        throwsA(isA<FrameFormatException>()),
      );
    });

    test('a frame at exactly the payload limit is still legal', () {
      final header = Uint8List(8);
      header[0] = MessageType.output.code;
      ByteData.view(
        header.buffer,
      ).setUint32(4, Frame.maxPayloadBytes, Endian.big);
      expect(
        FrameParser().add(header),
        isEmpty,
        reason: 'accepted, just not complete yet',
      );
    });

    test('readFrames turns a byte stream into a frame stream', () async {
      final bytes = Frame(MessageType.hello, 0, body(4)).encode();
      final frames = await readFrames(
        Stream.fromIterable([bytes.sublist(0, 3), bytes.sublist(3)]),
      ).toList();
      expect(frames, hasLength(1));
      expect(frames.single.type, MessageType.hello);
    });
  });
}
