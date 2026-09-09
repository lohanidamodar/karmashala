import 'dart:typed_data';

import 'package:karmashala_devices/src/data/scrcpy_protocol.dart';
import 'package:test/test.dart';

/// Builds a 12-byte scrcpy frame header followed by [payload].
Uint8List _frame(
  List<int> payload, {
  int ptsUs = 0,
  bool config = false,
  bool key = false,
}) {
  var ptsAndFlags = ptsUs;
  if (config) ptsAndFlags |= 1 << 62;
  if (key) ptsAndFlags |= 1 << 61;
  final b = BytesBuilder();
  final header = ByteData(12)
    ..setUint64(0, ptsAndFlags)
    ..setUint32(8, payload.length);
  b.add(header.buffer.asUint8List());
  b.add(payload);
  return b.toBytes();
}

Uint8List _sessionMeta(int width, int height) {
  final d = ByteData(12)
    ..setUint32(0, 0x80000000) // SESSION flag lives in the top int32
    ..setUint32(4, width)
    ..setUint32(8, height);
  return d.buffer.asUint8List();
}

void main() {
  group('ScrcpyStreamParser', () {
    test('reads the codec id first', () {
      final packets = ScrcpyStreamParser().add(
        Uint8List.fromList('h264'.codeUnits),
      );
      expect(packets.single, isA<ScrcpyCodec>());
      expect((packets.single as ScrcpyCodec).id, 'h264');
    });

    test('parses session meta, which carries geometry and no payload', () {
      final parser = ScrcpyStreamParser()..add('h264'.codeUnits);
      final packets = parser.add(_sessionMeta(460, 1024));
      expect(packets.single, isA<ScrcpySessionMeta>());
      final meta = packets.single as ScrcpySessionMeta;
      expect(meta.width, 460);
      expect(meta.height, 1024);
    });

    test('distinguishes config, keyframe and delta frames', () {
      final parser = ScrcpyStreamParser()..add('h264'.codeUnits);
      final packets = parser.add([
        ..._frame([1, 2, 3], config: true),
        ..._frame([4, 5], ptsUs: 1000, key: true),
        ..._frame([6], ptsUs: 2000),
      ]);
      expect(packets, hasLength(3));

      final config = packets[0] as ScrcpyFrame;
      expect(config.isConfig, isTrue);
      expect(config.data, [1, 2, 3]);

      final key = packets[1] as ScrcpyFrame;
      expect(key.isKeyFrame, isTrue);
      expect(key.isConfig, isFalse);
      expect(key.ptsUs, 1000);

      final delta = packets[2] as ScrcpyFrame;
      expect(delta.isKeyFrame, isFalse);
      expect(delta.ptsUs, 2000);
    });

    test('reassembles packets split across arbitrary chunk boundaries', () {
      final whole = Uint8List.fromList([
        ...'h264'.codeUnits,
        ..._sessionMeta(460, 1024),
        ..._frame(List.filled(300, 7), ptsUs: 5, key: true),
      ]);
      final parser = ScrcpyStreamParser();
      final collected = <ScrcpyPacket>[];
      // One byte at a time is the harshest fragmentation TCP could inflict.
      for (final byte in whole) {
        collected.addAll(parser.add([byte]));
      }
      expect(collected.whereType<ScrcpyCodec>(), hasLength(1));
      expect(collected.whereType<ScrcpySessionMeta>(), hasLength(1));
      final frames = collected.whereType<ScrcpyFrame>().toList();
      expect(frames, hasLength(1));
      expect(frames.single.data, hasLength(300));
      expect(frames.single.isKeyFrame, isTrue);
    });

    test('yields nothing until a payload is fully arrived', () {
      final parser = ScrcpyStreamParser()..add('h264'.codeUnits);
      final full = _frame(List.filled(100, 1), ptsUs: 1);
      expect(parser.add(full.sublist(0, 50)), isEmpty);
      expect(parser.add(full.sublist(50)), hasLength(1));
    });

    test('handles a rotation: session meta arriving mid-stream', () {
      final parser = ScrcpyStreamParser()..add('h264'.codeUnits);
      final packets = parser.add([
        ..._frame([1], ptsUs: 1),
        ..._sessionMeta(1024, 460),
        ..._frame([2], ptsUs: 2),
      ]);
      expect(packets[0], isA<ScrcpyFrame>());
      expect((packets[1] as ScrcpySessionMeta).width, 1024);
      expect((packets[2] as ScrcpyFrame).ptsUs, 2);
    });
  });
}
