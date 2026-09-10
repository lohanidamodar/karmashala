import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:karmashala_media/media.dart';
import 'package:karmashala/src/features/terminal/data/cast_frame_renderer.dart';
import 'package:karmashala_terminal_core/cast.dart';
import 'package:path/path.dart' as p;
import 'package:xterm2/xterm.dart';

import '../../support/temp_directory.dart';

TerminalCast _cast(List<CastEvent> events, {int columns = 40, int rows = 8}) =>
    TerminalCast(
      columns: columns,
      rows: rows,
      recordedAt: DateTime.utc(2026, 9, 8),
      title: 'pwsh',
      events: events,
    );

CastFrameStyle _style({int width = 320, int height = 180}) => CastFrameStyle(
  width: width,
  height: height,
  theme: TerminalThemes.defaultTheme,
  fontFamily: 'monospace',
  title: 'pwsh',
  padding: 8,
  titleBarHeight: 12,
);

/// Collects frames without encoding, so a test about rendering is about
/// rendering.
class _CollectingSink implements FrameSink {
  final frames = <RgbaFrame>[];
  bool closed = false;
  bool aborted = false;

  @override
  Future<void> addFrame(RgbaFrame frame) async => frames.add(frame);

  @override
  Future<FrameSinkResult> close() async {
    closed = true;
    return FrameSinkResult(path: 'memory', frames: frames.length, bytes: 0);
  }

  @override
  Future<void> abort() async => aborted = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('planCastPlayback', () {
    test('cuts the recording into frames at the asked-for rate', () {
      final playback = planCastPlayback(
        _cast([
          const CastEvent.output(Duration.zero, 'a'),
          const CastEvent.output(Duration(seconds: 1), 'b'),
        ]),
        frameRate: 10,
        tailHold: Duration.zero,
      );

      expect(playback.frameCount, 10);
      expect(playback.duration, const Duration(seconds: 1));
    });

    test('every event lands in exactly one frame', () {
      final playback = planCastPlayback(
        _cast([
          for (var i = 0; i < 25; i++)
            CastEvent.output(Duration(milliseconds: i * 37), 'x'),
        ]),
        frameRate: 10,
      );

      final placed = playback.steps.expand((s) => s.events).length;
      expect(placed, 25);
    });

    test('collapses dead air down to the idle cap', () {
      final long = planCastPlayback(
        _cast([
          const CastEvent.output(Duration.zero, 'build…'),
          const CastEvent.output(Duration(seconds: 60), 'done'),
        ]),
        frameRate: 10,
        idleCap: const Duration(seconds: 2),
        tailHold: Duration.zero,
      );
      // Sixty seconds of nothing becomes two, so the output is 2 s not 60 s.
      expect(long.duration, const Duration(seconds: 2));
      expect(long.frameCount, 20);

      // And the events are still both there, in order.
      final all = long.steps.expand((s) => s.events).toList();
      expect(all.map((e) => e.data), ['build…', 'done']);
    });

    test('an empty cast is the tail hold of an empty terminal', () {
      final playback = planCastPlayback(_cast(const []), frameRate: 10);
      // Nothing happened, so nothing is written — but the frames exist, because
      // an empty terminal is what was on screen and a file with no frames is
      // not a recording.
      expect(playback.duration, greaterThanOrEqualTo(kCastTailHold));
      expect(playback.steps.expand((s) => s.events), isEmpty);

      // And with no tail asked for, exactly the one frame.
      final bare = planCastPlayback(
        _cast(const []),
        frameRate: 10,
        tailHold: Duration.zero,
      );
      expect(bare.frameCount, 1);
      expect(bare.steps.single.events, isEmpty);
    });
  });

  group('CastFrameRenderer', () {
    test('renders one frame per planned step, at the framed size', () async {
      final cast = _cast([
        const CastEvent.output(Duration.zero, 'hello\r\n'),
        const CastEvent.output(Duration(milliseconds: 500), 'world\r\n'),
      ]);
      final sink = _CollectingSink();

      final progress = <int>[];
      await CastFrameRenderer(
        cast: cast,
        style: _style(),
        frameRate: 4,
      ).renderTo(sink, onProgress: (done, _) => progress.add(done));

      final planned = planCastPlayback(cast, frameRate: 4).frameCount;
      expect(sink.frames, hasLength(planned));
      expect(progress, List.generate(planned, (i) => i + 1));
      expect(sink.closed, isTrue);
      for (final frame in sink.frames) {
        expect(frame.width, 320);
        expect(frame.height, 180);
        expect(frame.rgba.lengthInBytes, 320 * 180 * 4);
      }
    });

    test('paints the window chrome onto an opaque ground', () async {
      final sink = _CollectingSink();
      await CastFrameRenderer(
        cast: _cast([const CastEvent.output(Duration.zero, 'x')]),
        style: _style(),
        frameRate: 4,
      ).renderTo(sink);

      final rgba = sink.frames.first.rgba;
      // Every pixel opaque — a transparent frame is what forgetting the ground
      // looks like, and it encodes to a black GIF.
      for (var i = 3; i < rgba.length; i += 4) {
        expect(rgba[i], 255, reason: 'alpha at byte $i');
      }
      // The ground behind the window is darker than the window itself.
      int luma(int x, int y) {
        final o = (y * 320 + x) * 4;
        return rgba[o] + rgba[o + 1] + rgba[o + 2];
      }

      expect(luma(1, 1), lessThan(luma(160, 90)));
    });

    test('a mid-recording resize is applied to the replayed grid', () async {
      final sink = _CollectingSink();
      final cast = _cast([
        const CastEvent.output(Duration.zero, 'before'),
        CastEvent.resize(const Duration(milliseconds: 300), 100, 20),
        const CastEvent.output(Duration(milliseconds: 400), 'after'),
      ]);

      // The frame is cut for the widest grid the cast ever had, so the later,
      // larger grid still fits.
      expect(cast.widestGrid, (columns: 100, rows: 20));
      await CastFrameRenderer(
        cast: cast,
        style: _style(),
        frameRate: 4,
      ).renderTo(sink);
      expect(sink.frames, isNotEmpty);
    });

    test('cancelling aborts the sink instead of finishing the file', () async {
      final sink = _CollectingSink();
      var rendered = 0;
      await expectLater(
        CastFrameRenderer(
          cast: _cast([
            const CastEvent.output(Duration.zero, 'a'),
            const CastEvent.output(Duration(seconds: 2), 'b'),
          ]),
          style: _style(),
          frameRate: 8,
        ).renderTo(
          sink,
          onProgress: (done, _) => rendered = done,
          cancelled: () => rendered >= 3,
        ),
        throwsA(isA<CastRenderCancelled>()),
      );
      expect(sink.aborted, isTrue);
      expect(sink.closed, isFalse);
    });
  });

  group('FrameEncoder', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('castrec'));
    tearDown(() => removeTempDirectory(temp));

    RgbaFrame solid(int value) => RgbaFrame(
      rgba: Uint8List.fromList(
        List.filled(8 * 8 * 4, 255)
          ..setRange(0, 8 * 8 * 4, [
            for (var i = 0; i < 8 * 8; i++) ...[value, value, value, 255],
          ]),
      ),
      width: 8,
      height: 8,
      hold: const Duration(milliseconds: 100),
    );

    test('writes a GIF a decoder can read back frame for frame', () async {
      final path = p.join(temp.path, 'recording.gif');
      final encoder = FrameEncoder(
        format: RecordingFormat.gif,
        outputPath: path,
      );
      encoder
        ..add(solid(0x20))
        ..add(solid(0x80))
        ..add(solid(0xE0));
      final result = await encoder.finish();

      expect(result.frames, 3);
      expect(result.needsExternalTool, isFalse);
      expect(result.externalCommand, isNull);

      final bytes = File(path).readAsBytesSync();
      expect(String.fromCharCodes(bytes.take(6)), 'GIF89a');
      final decoded = img.decodeGif(bytes);
      expect(decoded, isNotNull);
      expect(decoded!.frames, hasLength(3));
      expect(decoded.width, 8);
      expect(decoded.height, 8);
    });

    test('writes one PNG per frame and the ffmpeg line beside them', () async {
      final dir = p.join(temp.path, 'frames');
      final encoder = FrameEncoder(
        format: RecordingFormat.pngSequence,
        outputPath: dir,
        frameRate: 12,
      );
      encoder
        ..add(solid(0x11))
        ..add(solid(0x22));
      final result = await encoder.finish();

      expect(result.frames, 2);
      expect(File(p.join(dir, 'frame_00000.png')).existsSync(), isTrue);
      expect(File(p.join(dir, 'frame_00001.png')).existsSync(), isTrue);
      expect(img.decodePng(File(p.join(dir, 'frame_00000.png'))
          .readAsBytesSync())!.width, 8);

      // The file the user cannot get without a tool this app does not bundle is
      // named as needing one, and the command is on disk beside the frames.
      expect(result.externalTool, 'ffmpeg');
      expect(result.externalCommand, contains('frame_%05d.png'));
      expect(result.externalCommand, contains('-framerate 12'));
      expect(
        File(p.join(dir, 'render-mp4.txt')).readAsStringSync(),
        contains('ffmpeg'),
      );
    });
  });

  group('IsolateFrameSink', () {
    test('encodes off this isolate and hands back the finished file', () async {
      final temp = Directory.systemTemp.createTempSync('castrec-iso');
      addTearDown(() => removeTempDirectory(temp));
      final path = p.join(temp.path, 'out.gif');
      final sink = IsolateFrameSink(
        format: RecordingFormat.gif,
        outputPath: path,
      );

      await CastFrameRenderer(
        cast: _cast([const CastEvent.output(Duration.zero, 'hi')]),
        style: _style(width: 160, height: 96),
        frameRate: 4,
      ).renderTo(sink);

      expect(sink.frameCount, greaterThan(0));
      final bytes = File(path).readAsBytesSync();
      expect(String.fromCharCodes(bytes.take(6)), 'GIF89a');
      final decoded = img.decodeGif(bytes)!;
      expect(decoded.width, 160);
      expect(decoded.height, 96);
      expect(decoded.frames, hasLength(sink.frameCount));
    });
  });
}
