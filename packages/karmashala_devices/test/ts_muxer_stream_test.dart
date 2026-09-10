// The muxer judged as a whole stream rather than a packet at a time: the
// loop-27 muxer passed every packet-level test and still produced a stream that
// made mpv log `mpegts: Packet corrupt` and hold every frame back.
import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala_devices/src/data/scrcpy_protocol.dart';
import 'package:karmashala_devices/src/data/ts_muxer.dart';
import 'package:test/test.dart';

import './ts_stream_validator.dart';

/// 30 frames of real H.264 captured from `emulator-5554` over scrcpy 4.1
/// (`max_size=640 max_fps=20`), in scrcpy's framed wire format.
const _capture = 'test/fixtures/scrcpy_capture.bin';

Uint8List _unit(int length, [int fill = 0xAB]) =>
    Uint8List.fromList(List.filled(length, fill));

void main() {
  group('TsMuxer, read as a stream', () {
    test('every access-unit size produces a structurally valid stream', () {
      final muxer = TsMuxer();
      final out = BytesBuilder();
      out.add(muxer.tables());
      // Sizes chosen to cross every packetisation boundary.
      final sizes = [for (var n = 1; n <= 400; n++) n, 1000, 5000, 65521];
      var pts = 0;
      for (final size in sizes) {
        out.add(muxer.frame(_unit(size), pts, keyframe: pts == 0));
        pts += 50000;
      }
      final report = validateTransportStream(out.toBytes());
      expect(report.errors, isEmpty, reason: report.toString());
      expect(report.pes, hasLength(sizes.length));
      for (var i = 0; i < sizes.length; i++) {
        expect(
          report.pes[i].payload,
          hasLength(sizes[i]),
          reason: 'frame $i lost or gained bytes',
        );
      }
    });

    test('declares the PES length so the demuxer need not wait for the next '
        'frame', () {
      final muxer = TsMuxer();
      final report = validateTransportStream(
        muxer.frame(_unit(5000), 0, keyframe: true),
      );
      expect(report.errors, isEmpty, reason: report.toString());
      expect(report.pes.single.declaredLength, 3 + 5 + 5000);
      expect(
        report.pes.single.emittedImmediately,
        isTrue,
        reason: 'a declared length is what lets FFmpeg emit on the last byte',
      );
    });

    test('falls back to an unbounded PES when the frame will not fit in 16 '
        'bits', () {
      // 3 + 5 + payload must fit in 0xFFFF, so 65528 bytes is the largest that
      // can declare a length.
      final muxer = TsMuxer();
      expect(
        validateTransportStream(
          muxer.frame(_unit(65527), 0, keyframe: true),
        ).pes.single.declaredLength,
        0xFFFF,
      );
      expect(
        validateTransportStream(
          TsMuxer().frame(_unit(65528), 0, keyframe: true),
        ).pes.single.declaredLength,
        0,
        reason: 'one byte more must use the unbounded form',
      );
    });

    test('repeats PAT and PMT at least every table period', () {
      final muxer = TsMuxer();
      final out = BytesBuilder();
      // 30 frames a second apart, only the first a keyframe: the loop-27 muxer
      // emitted tables once here, because it tied them to keyframes.
      for (var i = 0; i < 30; i++) {
        out.add(muxer.frame(_unit(300), i * 1000000, keyframe: i == 0));
      }
      final report = validateTransportStream(out.toBytes());
      expect(report.errors, isEmpty, reason: report.toString());
      expect(report.patPackets, hasLength(30));
      expect(report.pmtPackets, hasLength(30));
    });

    test('rebases timestamps so a long-running device cannot wrap 33 bits', () {
      // scrcpy hands us the device's monotonic clock. Past ~26.5 h of uptime a
      // 90 kHz timestamp no longer fits in the 33 bits MPEG-TS allows.
      const uptimeUs = 40 * 3600 * 1000000;
      final muxer = TsMuxer();
      final report = validateTransportStream(
        muxer.frame(_unit(200), uptimeUs, keyframe: true),
      );
      expect(report.errors, isEmpty, reason: report.toString());
      expect(report.pes.single.pts90, 0);
      expect(muxer.basePtsUs, uptimeUs);
    });

    test('a backwards step costs one frame, not the rest of the session', () {
      // Clamping to the highest timestamp seen does not clamp one frame, it
      // latches: PTS and PCR then stop advancing while bytes keep flowing.
      final muxer = TsMuxer();
      final out = BytesBuilder()
        ..add(muxer.frame(_unit(100), 1000000, keyframe: true))
        ..add(muxer.frame(_unit(100), 1100000, keyframe: false))
        ..add(muxer.frame(_unit(100), 1050000, keyframe: false))
        ..add(muxer.frame(_unit(100), 1150000, keyframe: false));
      final report = validateTransportStream(out.toBytes());
      expect(report.errors, isEmpty, reason: report.toString());
      expect(report.pes.map((p) => p.pts90), [0, 9000, 10440, 19440]);
    });

    test('an idle gap does not become a gap in the stream', () {
      // scrcpy encodes on change, so an untouched phone sends nothing for
      // minutes: a viewer attaching after two minutes of idle got 120 seconds
      // of PCR in one step, on its second frame.
      final muxer = TsMuxer();
      final out = BytesBuilder()
        ..add(muxer.frame(_unit(64), 5000000, keyframe: true))
        ..add(muxer.frame(_unit(64), 125000000, keyframe: false))
        ..add(muxer.frame(_unit(64), 125016000, keyframe: false));
      final report = validateTransportStream(out.toBytes());
      expect(report.errors, isEmpty, reason: report.toString());
      expect(report.pes.map((p) => p.pts90), [0, 1440, 2880]);
      expect(
        report.maxPcrGap90,
        lessThan(90000),
        reason: 'no jump longer than a second reaches the demuxer',
      );
    });

    test('one impossible timestamp does not stop the clock', () {
      final muxer = TsMuxer();
      final out = BytesBuilder();
      for (final pts in [0, 16000, 32000, 9999999999, 48000, 64000]) {
        out.add(muxer.frame(_unit(48), pts, keyframe: pts == 0));
      }
      final report = validateTransportStream(out.toBytes());
      expect(report.errors, isEmpty, reason: report.toString());
      expect(report.pes.map((p) => p.pts90), [0, 1440, 2880, 4320, 5760, 7200]);
    });

    test('the stream clock only ever moves forward', () {
      final muxer = TsMuxer();
      final out = BytesBuilder();
      // Every shape of device clock at once: normal, repeated, backwards, a
      // long idle, and a spike.
      for (final pts in [
        1000000,
        1016000,
        1016000,
        1000000,
        900000,
        200000000,
        200016000,
        1 << 40,
        200032000,
      ]) {
        out.add(muxer.frame(_unit(24), pts, keyframe: pts == 1000000));
      }
      final report = validateTransportStream(out.toBytes());
      expect(report.errors, isEmpty, reason: report.toString());
      final stamps = report.pes.map((p) => p.pts90).toList();
      expect(stamps, everyElement(isNotNull));
      for (var i = 1; i < stamps.length; i++) {
        expect(
          stamps[i]!,
          greaterThan(stamps[i - 1]!),
          reason: 'frame $i went backwards or stood still: $stamps',
        );
      }
    });

    test('flags the first video packet discontinuous', () {
      // A player reconnecting sees continuity counters restart at zero; without
      // this flag FFmpeg calls that a corrupt packet.
      final bytes = TsMuxer().frame(_unit(100), 0, keyframe: true);
      const firstVideo = 2 * kTsPacketSize;
      expect(bytes[firstVideo + 5] & 0x80, 0x80);
      final next = TsMuxer()
        ..frame(_unit(100), 0, keyframe: true)
        ..frame(_unit(100), 500000, keyframe: false);
      final second = next.frame(_unit(100), 600000, keyframe: false);
      expect(second[5] & 0x80, 0, reason: 'only the first packet is a break');
    });

    test('muxes a real scrcpy capture into a stream FFmpeg would not '
        'complain about', () {
      final file = File(_capture);
      expect(file.existsSync(), isTrue, reason: 'fixture missing');

      final packets = ScrcpyStreamParser().add(file.readAsBytesSync());
      final muxer = TsMuxer();
      final out = BytesBuilder()..add(muxer.tables());
      final units = <Uint8List>[];
      Uint8List? config;
      for (final packet in packets) {
        if (packet is! ScrcpyFrame) continue;
        if (packet.isConfig) {
          config = packet.data;
          continue;
        }
        final unit = packet.isKeyFrame && config != null
            ? Uint8List.fromList([...config, ...packet.data])
            : packet.data;
        units.add(unit);
        out.add(muxer.frame(unit, packet.ptsUs, keyframe: packet.isKeyFrame));
      }

      expect(units, isNotEmpty);
      final report = validateTransportStream(out.toBytes());
      expect(report.errors, isEmpty, reason: report.toString());
      expect(report.videoPid, kVideoPid);
      expect(report.pcrPid, kVideoPid);
      expect(report.pes, hasLength(units.length));
      for (var i = 0; i < units.length; i++) {
        expect(report.pes[i].payload, units[i], reason: 'frame $i changed');
        expect(report.pes[i].emittedImmediately, isTrue, reason: 'frame $i');
      }
      // PCR must not drift from PTS: they are the same clock here.
      expect(report.pcr90, hasLength(units.length));
    });
  });
}
