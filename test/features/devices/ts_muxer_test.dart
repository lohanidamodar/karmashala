import 'dart:typed_data';

import 'package:chitragupta/src/features/devices/data/ts_muxer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('mpegCrc32', () {
    test('matches the standard CRC-32/MPEG-2 check value', () {
      // The published check value for CRC-32/MPEG-2 over ASCII "123456789".
      expect(mpegCrc32('123456789'.codeUnits), 0x0376E6E7);
    });
  });

  group('TsMuxer', () {
    test('emits whole 188-byte packets that all start with the sync byte', () {
      final bytes = TsMuxer().frame(
        Uint8List.fromList(List.filled(500, 0xAB)),
        1000,
        keyframe: true,
      );
      expect(bytes.length % kTsPacketSize, 0);
      for (var i = 0; i < bytes.length; i += kTsPacketSize) {
        expect(bytes[i], 0x47, reason: 'packet at $i lacks the sync byte');
      }
    });

    test('prepends PAT and PMT on a keyframe so a late joiner can start', () {
      final bytes = TsMuxer().frame(
        Uint8List.fromList([1, 2, 3]),
        0,
        keyframe: true,
      );
      int pidAt(int packet) {
        final base = packet * kTsPacketSize;
        return ((bytes[base + 1] & 0x1F) << 8) | bytes[base + 2];
      }

      expect(pidAt(0), 0x0000, reason: 'first packet should be the PAT');
      expect(pidAt(1), kPmtPid, reason: 'second packet should be the PMT');
      expect(pidAt(2), kVideoPid);
    });

    test('does not repeat the tables on a delta frame', () {
      final bytes = TsMuxer().frame(
        Uint8List.fromList([1, 2, 3]),
        0,
        keyframe: false,
      );
      final pid = ((bytes[1] & 0x1F) << 8) | bytes[2];
      expect(pid, kVideoPid);
    });

    test('increments the video continuity counter on every payload packet', () {
      final muxer = TsMuxer();
      // A payload large enough to need several packets.
      final bytes = muxer.frame(
        Uint8List.fromList(List.filled(1000, 0)),
        0,
        keyframe: false,
      );
      final counters = <int>[];
      for (var i = 0; i < bytes.length; i += kTsPacketSize) {
        counters.add(bytes[i + 3] & 0x0F);
      }
      for (var i = 1; i < counters.length; i++) {
        expect(
          counters[i],
          (counters[i - 1] + 1) % 16,
          reason: 'continuity must advance by one; a gap is read as data loss',
        );
      }
    });

    test('continuity continues across successive frames', () {
      final muxer = TsMuxer();
      final a = muxer.frame(Uint8List.fromList([1]), 0, keyframe: false);
      final b = muxer.frame(Uint8List.fromList([2]), 1000, keyframe: false);
      final last = a[a.length - kTsPacketSize + 3] & 0x0F;
      final next = b[3] & 0x0F;
      expect(next, (last + 1) % 16);
    });

    test('encodes a PTS in the 5-byte PES form with its marker bits', () {
      final encoded = TsMuxer.encodeTimestamp(90000, 0x2);
      expect(encoded, hasLength(5));
      expect(encoded[0] >> 4, 0x2, reason: 'prefix nibble');
      // Marker bit (LSB) must be set in bytes 0, 2 and 4.
      expect(encoded[0] & 1, 1);
      expect(encoded[2] & 1, 1);
      expect(encoded[4] & 1, 1);

      // Reconstruct the 33-bit value from the encoded form.
      final value =
          ((encoded[0] >> 1) & 0x07) << 30 |
          encoded[1] << 22 |
          ((encoded[2] >> 1) & 0x7F) << 15 |
          encoded[3] << 7 |
          ((encoded[4] >> 1) & 0x7F);
      expect(value, 90000);
    });

    test('marks the first packet of a keyframe as a random access point', () {
      final bytes = TsMuxer().frame(
        Uint8List.fromList(List.filled(400, 1)),
        5000,
        keyframe: true,
      );
      // Third packet is the first video packet (after PAT and PMT).
      const base = 2 * kTsPacketSize;
      expect(
        bytes[base + 3] >> 4 & 0x3,
        0x3,
        reason: 'adaptation field + payload',
      );
      expect(
        bytes[base + 5] & 0x40,
        0x40,
        reason: 'random_access_indicator must be set on a keyframe',
      );
      expect(bytes[base + 5] & 0x10, 0x10, reason: 'PCR must be present');
    });

    test('sets payload_unit_start only on the first packet of a frame', () {
      final bytes = TsMuxer().frame(
        Uint8List.fromList(List.filled(1000, 0)),
        0,
        keyframe: false,
      );
      final starts = <bool>[];
      for (var i = 0; i < bytes.length; i += kTsPacketSize) {
        starts.add(bytes[i + 1] & 0x40 != 0);
      }
      expect(starts.first, isTrue);
      expect(starts.skip(1).every((s) => !s), isTrue);
    });
  });
}
