import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:karmashala_media/media.dart';
import 'package:path/path.dart' as p;

import '../support/temp_directory.dart';

/// Stands in for the operating system's encoder so no test needs a real one.
class _FakeVideoEncoder implements VideoEncoder {
  _FakeVideoEncoder({
    required this.path,
    required this.width,
    required this.height,
  });

  final String path;
  final int width;
  final int height;
  final List<int> holds = <int>[];
  bool finished = false;
  bool aborted = false;

  @override
  void add(RgbaFrame frame) => holds.add(frame.hold.inMilliseconds);

  @override
  int finish() {
    finished = true;
    return 4096;
  }

  @override
  void abort() => aborted = true;
}

RgbaFrame _frame({int size = 64, int hold = 83, int value = 0x40}) {
  final rgba = Uint8List(size * size * 4);
  for (var i = 0; i < rgba.length; i += 4) {
    rgba[i] = value;
    rgba[i + 1] = value;
    rgba[i + 2] = value;
    rgba[i + 3] = 255;
  }
  return RgbaFrame(
    rgba: rgba,
    width: size,
    height: size,
    hold: Duration(milliseconds: hold),
  );
}

void main() {
  group('RecordingFormat', () {
    test('MP4 is a video and needs nothing installed', () {
      expect(RecordingFormat.mp4.isVideo, isTrue);
      expect(RecordingFormat.mp4.needsToolNote, isNull);
      expect(RecordingFormat.mp4.extension, 'mp4');
    });

    test('a PNG sequence still says it is not a video', () {
      expect(RecordingFormat.pngSequence.isVideo, isFalse);
      expect(RecordingFormat.pngSequence.needsToolNote, contains('ffmpeg'));
    });
  });

  group('FrameEncoder, MP4', () {
    late Directory temp;
    setUp(() => temp = Directory.systemTemp.createTempSync('fs-mp4'));
    tearDown(() => removeTempDirectory(temp));

    test('hands every frame to the encoder and reports its bytes', () async {
      _FakeVideoEncoder? made;
      final path = p.join(temp.path, 'out.mp4');
      final encoder = FrameEncoder(
        format: RecordingFormat.mp4,
        outputPath: path,
        openVideoEncoder:
            ({
              required String path,
              required int width,
              required int height,
              required int frameRate,
            }) => made = _FakeVideoEncoder(
              path: path,
              width: width,
              height: height,
            ),
      );
      encoder
        ..add(_frame(hold: 83))
        ..add(_frame(hold: 250));
      final result = await encoder.finish();

      expect(made!.path, path);
      expect(made!.width, 64);
      expect(made!.height, 64);
      // The holds go through: an idle stretch stays a long frame.
      expect(made!.holds, [83, 250]);
      expect(made!.finished, isTrue);
      expect(result.frames, 2);
      expect(result.bytes, 4096);
      // §19: a video says it is one, and asks nothing of the user.
      expect(result.needsExternalTool, isFalse);
      expect(result.externalCommand, isNull);
    });

    test(
      'finishing with no frames refuses rather than writing an empty file',
      () {
        final encoder = FrameEncoder(
          format: RecordingFormat.mp4,
          outputPath: p.join(temp.path, 'empty.mp4'),
          openVideoEncoder:
              ({
                required String path,
                required int width,
                required int height,
                required int frameRate,
              }) => _FakeVideoEncoder(path: path, width: width, height: height),
        );
        expect(encoder.finish(), throwsStateError);
      },
    );
  });

  group('IsolateFrameSink, MP4', () {
    late Directory temp;
    setUp(() => temp = Directory.systemTemp.createTempSync('fs-mp4-iso'));
    tearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } on Object {
        // Windows may still hold the file; the temp directory is disposable.
      }
    });

    test('encodes on the worker isolate and writes a real MP4', () async {
      final path = p.join(temp.path, 'iso.mp4');
      final sink = IsolateFrameSink(
        format: RecordingFormat.mp4,
        outputPath: path,
      );
      // Enough frames that the worker isolate goes round its message loop many
      // times, which is what would catch an encoder that minds its thread.
      for (var i = 0; i < 40; i++) {
        await sink.addFrame(_frame(value: i * 6));
      }
      final result = await sink.close();

      expect(result.frames, 40);
      expect(result.needsExternalTool, isFalse);
      final bytes = File(path).readAsBytesSync();
      expect(String.fromCharCodes(bytes.sublist(4, 8)), 'ftyp');
      expect(result.bytes, bytes.length);
    }, skip: !Platform.isWindows);

    test('abort leaves no half-written MP4 behind', () async {
      final path = p.join(temp.path, 'gone.mp4');
      final sink = IsolateFrameSink(
        format: RecordingFormat.mp4,
        outputPath: path,
      );
      await sink.addFrame(_frame());
      await sink.abort();
      expect(File(path).existsSync(), isFalse);
    }, skip: !Platform.isWindows);

    test('an encoder failure mid-recording removes the file and fails the '
        'next frame', () async {
      final path = p.join(temp.path, 'broken.mp4');
      final sink = IsolateFrameSink(
        format: RecordingFormat.mp4,
        outputPath: path,
      );
      await sink.addFrame(_frame(size: 64));
      // Smaller than the first frame: the encoder refuses it.
      await sink.addFrame(_frame(size: 32));
      Object? failure;
      for (var i = 0; i < 10 && failure == null; i++) {
        try {
          await sink.addFrame(_frame(size: 64));
        } on StateError catch (error) {
          failure = error;
        }
      }
      expect(failure, isA<StateError>());
      expect(sink.close(), throwsStateError);
      expect(File(path).existsSync(), isFalse);
    }, skip: !Platform.isWindows);
  });

  group('IsolateFrameSink, back-pressure', () {
    late Directory temp;
    setUp(() => temp = Directory.systemTemp.createTempSync('fs-window'));
    tearDown(() => removeTempDirectory(temp));

    test(
      'addFrame waits until the worker has landed the frame before it',
      () async {
        final dir = p.join(temp.path, 'seq');
        final sink = IsolateFrameSink(
          format: RecordingFormat.pngSequence,
          outputPath: dir,
        );
        for (var i = 0; i <= IsolateFrameSink.frameWindow; i++) {
          await sink.addFrame(_frame(size: 256));
        }
        // The window is full only once frame 0 was acknowledged, and the worker
        // acknowledges after the write.
        expect(File(p.join(dir, 'frame_00000.png')).existsSync(), isTrue);
        final result = await sink.close();
        expect(result.frames, IsolateFrameSink.frameWindow + 1);
      },
    );

    test('a worker that cannot write fails addFrame instead of taking more '
        'frames', () async {
      // A regular file where the sequence directory should be.
      final blocker = File(p.join(temp.path, 'seq'))..writeAsStringSync('x');
      final sink = IsolateFrameSink(
        format: RecordingFormat.pngSequence,
        outputPath: blocker.path,
      );
      Object? failure;
      for (var i = 0; i < 10 && failure == null; i++) {
        try {
          await sink.addFrame(_frame());
        } on StateError catch (error) {
          failure = error;
        }
      }
      expect(failure, isA<StateError>());
      expect(sink.close(), throwsStateError);
      await sink.abort();
    });
  });
}
