import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/devices/data/annex_b_splitter.dart';
import 'package:karmashala/src/features/devices/domain/simulator_backend.dart';

/// One Annex-B NAL unit: start code, header byte, payload.
///
/// [nri] only has to be non-zero for the parameter sets and reference slices;
/// nothing here reads it, but a realistic header byte keeps the fixtures
/// recognisable next to a hex dump of a real stream.
Uint8List _nal(int type, List<int> payload, {int startCode = 4, int nri = 3}) {
  final b = BytesBuilder();
  b.add(startCode == 4 ? const [0, 0, 0, 1] : const [0, 0, 1]);
  b.addByte((nri << 5) | type);
  b.add(payload);
  return b.toBytes();
}

/// A slice NAL. The first payload byte carries `first_mb_in_slice`: `0x80` set
/// means macroblock 0, i.e. the start of a new picture.
Uint8List _slice({
  required bool idr,
  int startCode = 4,
  bool firstMb = true,
  List<int> tail = const [0x11, 0x22, 0x33],
}) => _nal(
  idr ? 5 : 1,
  [firstMb ? 0x88 : 0x08, ...tail],
  startCode: startCode,
  nri: idr ? 3 : 2,
);

Uint8List _sps({int startCode = 4, int id = 0x42}) =>
    _nal(7, [id, 0x00, 0x1E, 0xAB], startCode: startCode);

Uint8List _pps({int startCode = 4, int id = 0xEE}) =>
    _nal(8, [id, 0x3C, 0x80], startCode: startCode);

Uint8List _aud({int startCode = 4}) =>
    _nal(9, [0x10], startCode: startCode, nri: 0);

Uint8List _sei({int startCode = 4}) =>
    _nal(6, [0x05, 0x02, 0xAA, 0xBB, 0x80], startCode: startCode, nri: 0);

Uint8List _join(List<Uint8List> parts) {
  final b = BytesBuilder();
  for (final p in parts) {
    b.add(p);
  }
  return b.toBytes();
}

/// A clock that advances a fixed step per reading, so PTS is a pure function of
/// how many units were emitted — and therefore comparable across chunkings.
int Function() _tickClock({int step = 1000, int start = 5000000}) {
  var now = start - step;
  return () => now += step;
}

/// Everything about a unit that must not depend on how the stream was chunked.
String _describe(VideoAccessUnit u) {
  final kind = u.isCodecConfig ? 'config' : (u.isKeyFrame ? 'key' : 'delta');
  final hex = u.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '$kind@${u.ptsUs}:$hex';
}

List<String> _describeAll(List<VideoAccessUnit> units) =>
    units.map(_describe).toList();

/// Feeds [stream] in slices of [chunkSize] bytes and flushes.
List<VideoAccessUnit> _feed(
  Uint8List stream, {
  int? chunkSize,
  int Function()? clockUs,
  int? maxPendingBytes,
}) {
  final splitter = AnnexBSplitter(
    clockUs: clockUs ?? _tickClock(),
    maxPendingBytes: maxPendingBytes ?? kMaxPendingBytes,
  );
  final out = <VideoAccessUnit>[];
  final size = chunkSize ?? stream.length;
  for (var i = 0; i < stream.length; i += size) {
    final end = i + size > stream.length ? stream.length : i + size;
    out.addAll(splitter.add(Uint8List.sublistView(stream, i, end)));
  }
  out.addAll(splitter.flush());
  return out;
}

void main() {
  group('access unit grouping', () {
    test('SPS + PPS + IDR become one keyframe access unit', () {
      final stream = _join([_sps(), _pps(), _slice(idr: true)]);
      final units = _feed(stream);

      // The parameter sets are published on their own first so the muxer can
      // cache them, then again as part of the picture they configure.
      expect(units.length, 2);
      expect(units[0].isCodecConfig, isTrue);
      expect(units[0].bytes, _join([_sps(), _pps()]));

      expect(units[1].isCodecConfig, isFalse);
      expect(units[1].isKeyFrame, isTrue);
      expect(units[1].bytes, stream);
    });

    test('a non-IDR slice is a non-keyframe access unit', () {
      final stream = _join([_slice(idr: false), _slice(idr: false)]);
      final units = _feed(stream);

      expect(units.length, 2);
      expect(units.every((u) => !u.isKeyFrame && !u.isCodecConfig), isTrue);
      expect(units[0].bytes, _slice(idr: false));
      expect(units[1].bytes, _slice(idr: false));
    });

    test('AUD and SEI are prefixes of the picture that follows them', () {
      final au1 = _join([_aud(), _sei(), _slice(idr: false)]);
      final au2 = _join([
        _aud(),
        _slice(idr: false, tail: const [0x44]),
      ]);
      final units = _feed(_join([au1, au2]));

      expect(units.length, 2);
      expect(units[0].bytes, au1);
      expect(units[1].bytes, au2);
    });

    test('two slices of one picture stay in one access unit', () {
      // A continuation slice has first_mb_in_slice != 0. Cutting between them
      // would hand the decoder two half-pictures with two timestamps.
      final picture = _join([
        _slice(idr: false, tail: const [0x01]),
        _slice(idr: false, firstMb: false, tail: const [0x02]),
      ]);
      final next = _slice(idr: false, tail: const [0x03]);
      final units = _feed(_join([picture, next]));

      expect(units.length, 2);
      expect(units[0].bytes, picture);
      expect(units[1].bytes, next);
    });

    test('flush emits the trailing access unit', () {
      final splitter = AnnexBSplitter(clockUs: _tickClock());
      final stream = _join([_sps(), _pps(), _slice(idr: true)]);

      final fromAdd = splitter.add(stream);
      // Nothing delimits the IDR yet: only the end of the stream can.
      expect(fromAdd.where((u) => !u.isCodecConfig), isEmpty);

      final fromFlush = splitter.flush();
      expect(fromFlush.length, 1);
      expect(fromFlush.single.isKeyFrame, isTrue);
      expect(fromFlush.single.bytes, stream);

      // A second flush has nothing left to give.
      expect(splitter.flush(), isEmpty);
    });
  });

  group('start codes', () {
    test('3-byte start codes are recognised', () {
      final stream = _join([
        _sps(startCode: 3),
        _pps(startCode: 3),
        _slice(idr: true, startCode: 3),
        _slice(idr: false, startCode: 3),
      ]);
      final units = _feed(stream).where((u) => !u.isCodecConfig).toList();

      expect(units.length, 2);
      expect(units[0].isKeyFrame, isTrue);
      expect(
        units[0].bytes,
        _join([
          _sps(startCode: 3),
          _pps(startCode: 3),
          _slice(idr: true, startCode: 3),
        ]),
      );
      expect(units[1].bytes, _slice(idr: false, startCode: 3));
    });

    test('3- and 4-byte start codes mix freely in one stream', () {
      final au1 = _join([
        _sps(startCode: 4),
        _pps(startCode: 3),
        _slice(idr: true, startCode: 4),
      ]);
      final au2 = _slice(idr: false, startCode: 3);
      final au3 = _slice(idr: false, startCode: 4, tail: const [0x99]);
      final units = _feed(
        _join([au1, au2, au3]),
      ).where((u) => !u.isCodecConfig).toList();

      expect(units.map((u) => u.bytes).toList(), [au1, au2, au3]);
    });

    test('a NAL ending in a zero byte keeps its zero', () {
      // `.. 00 | 00 00 00 01` is a NAL whose last byte is zero followed by a
      // 4-byte start code. Reading the boundary one byte early would strip the
      // zero off this picture and hand the next one a 3-byte start code.
      final ending = _slice(idr: false, tail: const [0x77, 0x00]);
      final next = _slice(idr: false, tail: const [0x78]);
      final units = _feed(_join([ending, next]));

      expect(units.length, 2);
      expect(units[0].bytes, ending);
      expect(units[1].bytes, next);
    });

    test('a run of zeros before a start code does not swallow the NAL', () {
      final stream = Uint8List.fromList([
        ..._slice(idr: false, tail: const [0x77]),
        0x00, 0x00, // trailing_zero_8bits after the NAL
        ..._slice(idr: true),
      ]);
      final units = _feed(stream).where((u) => !u.isCodecConfig).toList();

      expect(units.length, 2);
      expect(units[1].isKeyFrame, isTrue);
      // Whatever the split point, the bytes still concatenate back to the input.
      expect(_join(units.map((u) => u.bytes).toList()), stream);
    });
  });

  group('chunk boundaries', () {
    final stream = _join([
      _sps(),
      _pps(startCode: 3),
      _slice(idr: true),
      _aud(startCode: 3),
      _slice(idr: false, tail: const [0xA1, 0xA2]),
      _sei(),
      _slice(idr: false, startCode: 3, tail: const [0xB1]),
      _slice(idr: true, startCode: 4, tail: const [0xC1, 0x00]),
    ]);

    test('a start code split at every possible offset parses identically', () {
      final whole = _describeAll(_feed(stream));
      expect(whole, isNotEmpty);

      for (var split = 1; split < stream.length; split++) {
        final splitter = AnnexBSplitter(clockUs: _tickClock());
        final units = <VideoAccessUnit>[
          ...splitter.add(Uint8List.sublistView(stream, 0, split)),
          ...splitter.add(Uint8List.sublistView(stream, split)),
          ...splitter.flush(),
        ];
        expect(
          _describeAll(units),
          whole,
          reason: 'chunk boundary at byte $split changed the output',
        );
      }
    });

    test('one byte at a time equals one whole chunk', () {
      expect(
        _describeAll(_feed(stream, chunkSize: 1)),
        _describeAll(_feed(stream)),
      );
    });

    test('every chunk size from 1 to the whole stream agrees', () {
      final whole = _describeAll(_feed(stream));
      for (var size = 1; size <= stream.length; size++) {
        expect(
          _describeAll(_feed(stream, chunkSize: size)),
          whole,
          reason: 'chunk size $size changed the output',
        );
      }
    });
  });

  group('bytes are preserved exactly', () {
    test('picture units concatenate back to the input stream', () {
      // No prepending can happen here: every keyframe already carries its own
      // parameter sets, so the pictures are a straight partition of the input.
      final stream = _join([
        _sps(),
        _pps(),
        _slice(idr: true),
        _slice(idr: false, tail: const [0x01]),
        _slice(idr: false, tail: const [0x02, 0x00]),
        _sps(),
        _pps(),
        _slice(idr: true, tail: const [0x03]),
      ]);
      final pictures = _feed(stream).where((u) => !u.isCodecConfig).toList();

      expect(pictures.length, 4);
      expect(_join(pictures.map((u) => u.bytes).toList()), stream);
    });

    test('emitted bytes are independent of the buffer they came from', () {
      final stream = _join([
        _slice(idr: false, tail: const [0x01]),
        _slice(idr: false, tail: const [0x02]),
        _slice(idr: false, tail: const [0x03]),
      ]);
      final splitter = AnnexBSplitter(clockUs: _tickClock());
      final first = splitter.add(stream).first;
      final before = Uint8List.fromList(first.bytes);

      // Later chunks must not be able to reach back into an emitted unit.
      splitter.add(_slice(idr: true));
      splitter.flush();
      expect(first.bytes, before);
    });
  });

  group('codec config', () {
    test('SPS + PPS are surfaced before any VCL NAL arrives', () {
      final splitter = AnnexBSplitter(clockUs: _tickClock());
      final units = <VideoAccessUnit>[
        ...splitter.add(_join([_sps(), _pps()])),
        ...splitter.flush(),
      ];

      expect(units.length, 1);
      expect(units.single.isCodecConfig, isTrue);
      expect(units.single.isKeyFrame, isFalse);
      expect(units.single.bytes, _join([_sps(), _pps()]));
    });

    test('config is published once, not before every keyframe', () {
      final stream = _join([
        _sps(),
        _pps(),
        _slice(idr: true),
        _sps(),
        _pps(),
        _slice(idr: true, tail: const [0x02]),
        _sps(),
        _pps(),
        _slice(idr: true, tail: const [0x03]),
      ]);
      final units = _feed(stream);

      expect(units.where((u) => u.isCodecConfig).length, 1);
      expect(units.where((u) => u.isKeyFrame).length, 3);
    });

    test('changed parameter sets are republished', () {
      final stream = _join([
        _sps(),
        _pps(),
        _slice(idr: true),
        _sps(id: 0x4D), // a rotation or resolution change
        _pps(),
        _slice(idr: true, tail: const [0x02]),
      ]);
      final configs = _feed(stream).where((u) => u.isCodecConfig).toList();

      expect(configs.length, 2);
      expect(configs[0].bytes, _join([_sps(), _pps()]));
      expect(configs[1].bytes, _join([_sps(id: 0x4D), _pps()]));
    });

    test('a lone SPS publishes nothing until a PPS joins it', () {
      final splitter = AnnexBSplitter(clockUs: _tickClock());
      splitter.add(_join([_sps(), _aud()]));
      expect(splitter.flush().where((u) => u.isCodecConfig), isEmpty);
    });

    test('cached config is prepended to a keyframe that lacks it', () {
      // idb's own shape: parameter sets once at the head of the stream, then
      // bare IDRs. A viewer joining at the second keyframe would otherwise have
      // nothing to configure the decoder with.
      final stream = _join([
        _sps(),
        _pps(),
        _slice(idr: true),
        _slice(idr: false),
        _slice(idr: true, tail: const [0x02]),
      ]);
      final units = _feed(stream);
      final keyframes = units.where((u) => u.isKeyFrame).toList();

      expect(keyframes.length, 2);
      // The first keyframe carries them already: no duplication.
      expect(keyframes[0].bytes, _join([_sps(), _pps(), _slice(idr: true)]));
      // The second does not, so it gets the cached pair in front.
      expect(
        keyframes[1].bytes,
        _join([
          _sps(),
          _pps(),
          _slice(idr: true, tail: const [0x02]),
        ]),
      );
    });

    test('non-keyframes are never given a config prefix', () {
      final stream = _join([
        _sps(),
        _pps(),
        _slice(idr: true),
        _slice(idr: false, tail: const [0x09]),
        _slice(idr: false, tail: const [0x0A]),
      ]);
      final deltas = _feed(
        stream,
      ).where((u) => !u.isKeyFrame && !u.isCodecConfig).toList();

      expect(deltas.length, 2);
      expect(deltas[0].bytes, _slice(idr: false, tail: const [0x09]));
      expect(deltas[1].bytes, _slice(idr: false, tail: const [0x0A]));
    });

    test('a keyframe before any config is left untouched', () {
      final units = _feed(_slice(idr: true));
      expect(units.length, 1);
      expect(units.single.isKeyFrame, isTrue);
      expect(units.single.bytes, _slice(idr: true));
    });
  });

  group('synthesised timestamps', () {
    test('the first unit is at zero and later ones step with the clock', () {
      final stream = _join([
        _sps(),
        _pps(),
        _slice(idr: true),
        _slice(idr: false, tail: const [0x01]),
        _slice(idr: false, tail: const [0x02]),
      ]);
      final units = _feed(stream, clockUs: _tickClock(step: 33000));

      expect(units.map((u) => u.ptsUs).toList(), [0, 33000, 66000, 99000]);
    });

    test('the clock is read once per unit, not once per chunk', () {
      final stream = _join([
        _slice(idr: false, tail: const [0x01]),
        _slice(idr: false, tail: const [0x02]),
        _slice(idr: false, tail: const [0x03]),
      ]);
      final whole = _feed(stream, clockUs: _tickClock(step: 7));
      final dribbled = _feed(
        stream,
        chunkSize: 1,
        clockUs: _tickClock(step: 7),
      );

      expect(whole.map((u) => u.ptsUs).toList(), [0, 7, 14]);
      expect(dribbled.map((u) => u.ptsUs).toList(), [0, 7, 14]);
    });

    test('timestamps are monotonic across the stream', () {
      final stream = _join([
        _sps(),
        _pps(),
        _slice(idr: true),
        for (var i = 0; i < 8; i++) _slice(idr: false, tail: [i]),
      ]);
      final pts = _feed(stream).map((u) => u.ptsUs).toList();

      for (var i = 1; i < pts.length; i++) {
        expect(pts[i], greaterThan(pts[i - 1]));
      }
    });
  });

  group('robustness', () {
    test('an empty chunk is a no-op', () {
      final splitter = AnnexBSplitter(clockUs: _tickClock());
      expect(splitter.add(const <int>[]), isEmpty);
      expect(splitter.add(_slice(idr: true)), isEmpty);
      expect(splitter.add(const <int>[]), isEmpty);
      expect(splitter.flush().single.isKeyFrame, isTrue);
    });

    test('leading garbage before the first start code is dropped', () {
      final picture = _slice(idr: true);
      final stream = Uint8List.fromList([
        0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x12, // no start code anywhere in here
        ...picture,
      ]);
      final units = _feed(stream);

      expect(units.length, 1);
      expect(units.single.bytes, picture);
    });

    test('a chunk with no start code accumulates rather than being lost', () {
      final picture = _slice(idr: false, tail: const [1, 2, 3, 4, 5, 6, 7, 8]);
      final splitter = AnnexBSplitter(clockUs: _tickClock());

      // Dribble the payload in with no delimiter in sight.
      for (var i = 0; i < picture.length; i++) {
        expect(splitter.add([picture[i]]), isEmpty);
      }
      expect(splitter.flush().single.bytes, picture);
    });

    test('a start code split across the boundary is still found', () {
      final picture = _slice(idr: true);
      final next = _slice(idr: false);
      final splitter = AnnexBSplitter(clockUs: _tickClock());
      final out = <VideoAccessUnit>[
        // The IDR's own 4-byte start code arrives as `00 00` then `00 01`, and
        // the next one is cut after three of its four bytes.
        ...splitter.add(picture.sublist(0, 2)),
        ...splitter.add([...picture.sublist(2), ...next.sublist(0, 3)]),
        ...splitter.add(next.sublist(3)),
        ...splitter.flush(),
      ];

      expect(out.length, 2);
      expect(out[0].bytes, picture);
      expect(out[1].bytes, next);
    });

    test('the pending buffer does not grow without bound', () {
      final splitter = AnnexBSplitter(
        clockUs: _tickClock(),
        maxPendingBytes: 64,
      );

      // A NAL is opened and then never closed. Garbage *before* the first start
      // code cannot pile up — it is compacted away every chunk — so this is the
      // only shape that can grow without limit.
      splitter.add(_nal(1, const [0x88]));
      splitter.add(List<int>.filled(200, 0xAB));
      expect(splitter.flush(), isEmpty);

      // The cap resyncs; it does not wedge the stream.
      final recovered = <VideoAccessUnit>[
        ...splitter.add(_join([_sps(), _pps(), _slice(idr: true)])),
        ...splitter.flush(),
      ];
      expect(recovered.where((u) => u.isKeyFrame).length, 1);
    });

    test('cached config survives a resync so the next keyframe decodes', () {
      final splitter = AnnexBSplitter(
        clockUs: _tickClock(),
        maxPendingBytes: 64,
      );
      splitter.add(_join([_sps(), _pps(), _aud()]));
      splitter.add(List<int>.filled(200, 0xAB)); // blows the cap
      final out = <VideoAccessUnit>[
        ...splitter.add(_slice(idr: true)),
        ...splitter.flush(),
      ];

      expect(out.single.isKeyFrame, isTrue);
      expect(out.single.bytes, _join([_sps(), _pps(), _slice(idr: true)]));
    });

    test('a start code with no payload byte does not crash the parser', () {
      final stream = Uint8List.fromList([
        0, 0, 0, 1, // an empty NAL
        ..._slice(idr: true),
      ]);
      expect(_feed(stream).where((u) => u.isKeyFrame).length, 1);
    });

    test('a stream that is nothing but garbage emits nothing', () {
      final units = _feed(Uint8List.fromList(List<int>.filled(500, 0x5A)));
      expect(units, isEmpty);
    });
  });
}
