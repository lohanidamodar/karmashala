import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// One rendered frame, as straight RGBA rows.
///
/// The currency of the whole encode side. Anything that can produce these —
/// a replayed terminal cast, a device's screen stream — can use any [FrameSink]
/// here without either side knowing about the other.
class RgbaFrame {
  const RgbaFrame({
    required this.rgba,
    required this.width,
    required this.height,
    required this.hold,
  });

  /// `width * height * 4` bytes, row-major, 8 bits per channel.
  final Uint8List rgba;
  final int width;
  final int height;

  /// How long this frame stays on screen.
  final Duration hold;
}

/// What a finished encode produced.
class FrameSinkResult {
  const FrameSinkResult({
    required this.path,
    required this.frames,
    required this.bytes,
    this.externalTool,
    this.externalCommand,
  });

  /// The file, or the directory of files, that was written.
  final String path;
  final int frames;
  final int bytes;

  /// The tool the user still has to run, when the sink could not finish the
  /// job on its own — `'ffmpeg'` for the frame sequence. Null means [path] is
  /// finished and playable.
  ///
  /// Never left null by a sink that only wrote half a video. A file the user's
  /// player cannot open is not a video, and calling it one is the failure this
  /// field exists to prevent.
  final String? externalTool;

  /// The exact command line that turns [path] into that tool's output.
  final String? externalCommand;

  bool get needsExternalTool => externalTool != null;
}

/// Turns a sequence of rendered frames into a file.
///
/// **The seam.** Rendering has to happen on the isolate that owns the Flutter
/// engine — `Picture.toImage` rasterises nowhere else — but encoding is pure
/// Dart arithmetic over bytes, and hundreds of frames of it would freeze the
/// app for the length of the recording. So the split is here: frames cross this
/// interface, and what is behind it is free to be somewhere else. [IsolateFrameSink]
/// is, and is the only implementation that ships.
abstract interface class FrameSink {
  /// Hands over one frame. Awaiting this is the back-pressure: a renderer that
  /// awaits cannot get further ahead of the encoder than one frame, so peak
  /// memory is one frame rather than the whole recording.
  Future<void> addFrame(RgbaFrame frame);

  /// Finishes the file and returns what was written.
  Future<FrameSinkResult> close();

  /// Gives up and cleans up. Safe to call after [close].
  Future<void> abort();
}

/// The formats a recording can be written as.
enum RecordingFormat {
  /// Plays anywhere with no tool at all, at the cost of 256 colours.
  gif('Animated GIF', 'gif'),

  /// Numbered PNGs plus the `ffmpeg` line that turns them into Full HD MP4.
  pngSequence('PNG frames + ffmpeg command', 'png');

  const RecordingFormat(this.label, this.extension);

  final String label;
  final String extension;

  /// What the user must be told before they pick this.
  ///
  /// [pngSequence] needs a tool this app does not bundle and will not pretend
  /// to have; saying so on the button is the whole point of the field.
  String? get needsToolNote => switch (this) {
    gif => null,
    pngSequence =>
      'Writes one PNG per frame and an ffmpeg command. '
          'This app does not bundle ffmpeg — you run the command yourself.',
  };
}

/// A [FrameSink] whose encoding runs on a worker isolate.
///
/// The worker holds the encoder's state and never sends a frame back, so the
/// only things crossing between isolates are the frames going in — as
/// [TransferableTypedData], which moves the bytes rather than copying them —
/// and one small result at the end.
class IsolateFrameSink implements FrameSink {
  IsolateFrameSink({
    required this.format,
    required this.outputPath,
    this.frameRate = kRecordingFrameRate,
  });

  final RecordingFormat format;

  /// The `.gif` file, or the directory the PNG sequence goes in.
  final String outputPath;
  final int frameRate;

  Isolate? _worker;
  SendPort? _commands;
  final _ready = Completer<void>();
  final _done = Completer<FrameSinkResult>();
  int _frames = 0;
  bool _closed = false;

  Future<void> _start() async {
    if (_worker != null) return _ready.future;
    final receive = ReceivePort();
    _worker = await Isolate.spawn(
      _encodeWorker,
      _EncodeRequest(
        reply: receive.sendPort,
        format: format,
        outputPath: outputPath,
        frameRate: frameRate,
      ),
      debugName: kFrameEncoderIsolateName,
      errorsAreFatal: true,
    );
    receive.listen((message) {
      switch (message) {
        case SendPort():
          _commands = message;
          if (!_ready.isCompleted) _ready.complete();
        case FrameSinkResult():
          if (!_done.isCompleted) _done.complete(message);
          receive.close();
        case _EncodeFailure():
          final error = StateError(message.message);
          if (!_ready.isCompleted) _ready.completeError(error);
          if (!_done.isCompleted) _done.completeError(error);
          receive.close();
      }
    });
    return _ready.future;
  }

  @override
  Future<void> addFrame(RgbaFrame frame) async {
    if (_closed) return;
    await _start();
    _frames++;
    _commands!.send(
      _EncodeFrame(
        bytes: TransferableTypedData.fromList([frame.rgba]),
        width: frame.width,
        height: frame.height,
        holdMicros: frame.hold.inMicroseconds,
      ),
    );
  }

  @override
  Future<FrameSinkResult> close() async {
    if (_closed) return _done.future;
    _closed = true;
    if (_worker == null) {
      // Nothing was ever rendered. An empty file would be the dishonest answer.
      throw StateError('no frames were rendered');
    }
    await _ready.future;
    _commands!.send(const _EncodeFinish());
    return _done.future;
  }

  @override
  Future<void> abort() async {
    _closed = true;
    _worker?.kill(priority: Isolate.immediate);
    _worker = null;
    if (!_done.isCompleted) {
      _done.completeError(StateError('encode aborted'));
      // Nobody may be awaiting it; keep the VM quiet about that.
      unawaited(_done.future.catchError((_) => throw StateError('aborted')));
    }
  }

  /// How many frames were handed over.
  int get frameCount => _frames;
}

/// Frames per second every recording is rendered and encoded at.
///
/// Twelve, not thirty: a terminal changes in bursts of whole lines rather than
/// continuously, so the extra frames cost their full encode and show nothing
/// new. GIF's own delay field is hundredths of a second, which 12 divides into
/// unevenly at 8.33 — the encoder rounds, and a third of a hundredth per frame
/// is below anything a viewer can see.
const int kRecordingFrameRate = 12;

const String kFrameEncoderIsolateName = 'karmashala.frame-encoder';

class _EncodeRequest {
  const _EncodeRequest({
    required this.reply,
    required this.format,
    required this.outputPath,
    required this.frameRate,
  });

  final SendPort reply;
  final RecordingFormat format;
  final String outputPath;
  final int frameRate;
}

class _EncodeFrame {
  const _EncodeFrame({
    required this.bytes,
    required this.width,
    required this.height,
    required this.holdMicros,
  });

  final TransferableTypedData bytes;
  final int width;
  final int height;
  final int holdMicros;
}

class _EncodeFinish {
  const _EncodeFinish();
}

class _EncodeFailure {
  const _EncodeFailure(this.message);

  final String message;
}

/// The worker's whole life: take frames, encode them, write the file, answer.
Future<void> _encodeWorker(_EncodeRequest request) async {
  final commands = ReceivePort();
  request.reply.send(commands.sendPort);
  final encoder = FrameEncoder(
    format: request.format,
    outputPath: request.outputPath,
    frameRate: request.frameRate,
  );
  await for (final message in commands) {
    try {
      switch (message) {
        case _EncodeFrame():
          encoder.add(
            RgbaFrame(
              rgba: message.bytes.materialize().asUint8List(),
              width: message.width,
              height: message.height,
              hold: Duration(microseconds: message.holdMicros),
            ),
          );
        case _EncodeFinish():
          request.reply.send(await encoder.finish());
          commands.close();
      }
    } catch (error) {
      request.reply.send(_EncodeFailure('$error'));
      commands.close();
    }
  }
}

/// The encoding itself — pure Dart, no `dart:ui`, so it runs wherever it is put.
///
/// Exposed rather than hidden inside the worker so a test can encode a handful
/// of frames without spawning an isolate, and so the device-recording work can
/// reuse the encode without inheriting this file's isolate plumbing.
class FrameEncoder {
  FrameEncoder({
    required this.format,
    required this.outputPath,
    this.frameRate = kRecordingFrameRate,
  });

  final RecordingFormat format;
  final String outputPath;
  final int frameRate;

  /// Octree rather than the package default's neural quantizer, and no dither.
  ///
  /// A terminal frame is a couple of dozen flat colours over one ground —
  /// nothing a 256-entry palette has to approximate. Neural spends its time
  /// learning a palette that octree can read straight off, and Floyd-Steinberg
  /// scatters the error it has none of across the glyph edges, which on text
  /// reads as grain.
  late final img.GifEncoder _gif = img.GifEncoder(
    quantizerType: img.QuantizerType.octree,
    dither: img.DitherKernel.none,
    repeat: 0,
  );

  int _frames = 0;

  void add(RgbaFrame frame) {
    final image = img.Image.fromBytes(
      width: frame.width,
      height: frame.height,
      bytes: frame.rgba.buffer,
      // A `ByteData.buffer` may be longer than the view onto it; say where the
      // pixels start rather than copying the whole thing to move them.
      bytesOffset: frame.rgba.offsetInBytes,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    switch (format) {
      case RecordingFormat.gif:
        // GIF delays are hundredths of a second, and zero means "as fast as the
        // viewer likes" in most players — clamp to one so a frame is never
        // skipped outright.
        final hundredths = (frame.hold.inMicroseconds / 10000).round();
        _gif.addFrame(image, duration: hundredths < 1 ? 1 : hundredths);
      case RecordingFormat.pngSequence:
        final dir = Directory(outputPath)..createSync(recursive: true);
        final name = 'frame_${_frames.toString().padLeft(5, '0')}.png';
        File(p.join(dir.path, name)).writeAsBytesSync(img.encodePng(image));
    }
    _frames++;
  }

  Future<FrameSinkResult> finish() async {
    switch (format) {
      case RecordingFormat.gif:
        final bytes = _gif.finish();
        if (bytes == null) throw StateError('no frames were encoded');
        final file = File(outputPath);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes);
        return FrameSinkResult(
          path: file.path,
          frames: _frames,
          bytes: bytes.length,
        );
      case RecordingFormat.pngSequence:
        final dir = Directory(outputPath);
        final command = ffmpegCommandFor(dir.path, frameRate: frameRate);
        await File(
          p.join(dir.path, 'render-mp4.txt'),
        ).writeAsString('$command\n');
        var total = 0;
        await for (final entry in dir.list()) {
          if (entry is File) total += await entry.length();
        }
        return FrameSinkResult(
          path: dir.path,
          frames: _frames,
          bytes: total,
          externalTool: 'ffmpeg',
          externalCommand: command,
        );
    }
  }
}

/// The command that turns a rendered frame sequence into a Full HD MP4.
///
/// Written into the folder beside the frames as well as shown, because a
/// command the user has to retype from a dialog is a command they will not run.
/// `yuv420p` and the even-dimension scale are what makes the result play in
/// QuickTime, PowerPoint and a browser rather than only in VLC.
String ffmpegCommandFor(String frameDirectory, {int frameRate = kRecordingFrameRate}) =>
    'ffmpeg -framerate $frameRate '
    '-i "${p.join(frameDirectory, 'frame_%05d.png')}" '
    '-vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" '
    '-c:v libx264 -pix_fmt yuv420p -crf 20 '
    '"${p.join(frameDirectory, 'recording.mp4')}"';
