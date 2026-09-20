import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'media_foundation.dart';
import 'video_writer.dart';

/// One rendered frame, as straight RGBA rows — the currency of the encode
/// side, so any producer works with any [FrameSink].
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

  /// The tool the user still has to run — `'ffmpeg'` for the frame sequence.
  /// Null only when [path] is finished and playable, never for a half-written
  /// file.
  final String? externalTool;

  /// The exact command line that turns [path] into that tool's output.
  final String? externalCommand;

  bool get needsExternalTool => externalTool != null;
}

/// Turns a sequence of rendered frames into a file.
///
/// The seam exists because `Picture.toImage` rasterises only on the engine's
/// isolate while the encode is pure byte arithmetic that would freeze the app
/// for the length of the recording; [IsolateFrameSink] is the only shipping
/// implementation.
abstract interface class FrameSink {
  /// Hands over one frame. Awaiting it is the back-pressure: peak memory is
  /// one frame rather than the whole recording.
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

  /// H.264 in MP4, written by the operating system's own encoder.
  mp4('MP4 video', 'mp4'),

  /// Numbered PNGs plus the `ffmpeg` line that turns them into Full HD MP4.
  pngSequence('PNG frames + ffmpeg command', 'png');

  const RecordingFormat(this.label, this.extension);

  final String label;
  final String extension;

  /// Whether the file this writes is a video, rather than a folder of pictures.
  bool get isVideo => this != pngSequence;

  /// What the user must be told before they pick this — [pngSequence] needs a
  /// tool the app does not bundle and will not pretend to have.
  String? get needsToolNote => switch (this) {
    gif => null,
    mp4 => null,
    pngSequence =>
      'Writes one PNG per frame and an ffmpeg command. '
          'This app does not bundle ffmpeg — you run the command yourself.',
  };
}

/// A [FrameSink] whose encoding runs on a worker isolate. Frames cross as
/// [TransferableTypedData], which moves the bytes rather than copying them;
/// nothing comes back but one small result.
class IsolateFrameSink implements FrameSink {
  IsolateFrameSink({
    required this.format,
    required this.outputPath,
    this.frameRate = kRecordingFrameRate,
    this.hardwareTransforms = appHardwareTransforms,
  });

  final RecordingFormat format;

  /// The `.gif` file, or the directory the PNG sequence goes in.
  final String outputPath;
  final int frameRate;

  /// Carried across to the worker, because a spawned isolate inherits nothing.
  final bool hardwareTransforms;

  /// Frames the worker may hold before [addFrame] waits: one encoding, one
  /// queued behind it. Peak memory stays at a couple of frames either way.
  static const int frameWindow = 2;

  Isolate? _worker;
  SendPort? _commands;
  final _ready = Completer<void>();
  final _done = Completer<FrameSinkResult>();
  final _aborted = Completer<void>();
  final _waiters = <Completer<void>>[];
  int _frames = 0;
  int _inFlight = 0;
  bool _closed = false;
  Object? _failure;

  Future<void> _start() async {
    if (_worker != null) return _ready.future;
    final receive = ReceivePort();
    final errors = ReceivePort();
    final exit = ReceivePort();
    _worker = await Isolate.spawn(
      _encodeWorker,
      _EncodeRequest(
        reply: receive.sendPort,
        format: format,
        outputPath: outputPath,
        frameRate: frameRate,
        hardwareTransforms: hardwareTransforms,
      ),
      debugName: kFrameEncoderIsolateName,
      errorsAreFatal: true,
      onError: errors.sendPort,
      onExit: exit.sendPort,
    );
    receive.listen(
      (message) {
        switch (message) {
          case SendPort():
            _commands = message;
            if (!_ready.isCompleted) _ready.complete();
          case _EncodeFrameDone():
            _inFlight--;
            _releaseWaiters(all: false);
          case FrameSinkResult():
            if (!_done.isCompleted) _done.complete(message);
            receive.close();
          case _EncodeAborted():
            if (!_aborted.isCompleted) _aborted.complete();
            receive.close();
          case _EncodeFailure():
            _fail(StateError(message.message));
            receive.close();
        }
      },
      onDone: () {
        if (!_aborted.isCompleted) _aborted.complete();
      },
    );
    errors.listen((message) {
      final detail = message is List && message.isNotEmpty
          ? message.first
          : message;
      _fail(StateError('frame encoder crashed: $detail'));
    });
    exit.listen((_) {
      errors.close();
      exit.close();
      receive.close();
      // A worker that finished has already answered; one that has not, never will.
      _fail(StateError('frame encoder exited before finishing'));
    });
    return _ready.future;
  }

  /// Records the first failure and wakes everyone waiting on the worker.
  void _fail(Object error) {
    _failure ??= error;
    if (!_ready.isCompleted) {
      _ready.completeError(error);
      _ready.future.ignore();
    }
    if (!_done.isCompleted) {
      _done.completeError(error);
      _done.future.ignore();
    }
    if (!_aborted.isCompleted) _aborted.complete();
    _releaseWaiters(all: true);
  }

  void _releaseWaiters({required bool all}) {
    if (_waiters.isEmpty) return;
    if (all) {
      for (final waiter in _waiters) {
        waiter.complete();
      }
      _waiters.clear();
    } else {
      _waiters.removeAt(0).complete();
    }
  }

  /// Blocks while the worker holds [frameWindow] frames, and throws the
  /// worker's failure rather than sending more frames after it.
  @override
  Future<void> addFrame(RgbaFrame frame) async {
    if (_closed) return;
    await _start();
    while (_inFlight >= frameWindow && !_closed && _failure == null) {
      final credit = Completer<void>();
      _waiters.add(credit);
      await credit.future;
    }
    if (_failure case final failure?) throw failure;
    if (_closed) return;
    _frames++;
    _inFlight++;
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
    if (_closed || _failure != null) return _done.future;
    _closed = true;
    if (_worker == null) {
      // Nothing was ever rendered. An empty file would be the dishonest answer.
      throw StateError('no frames were rendered');
    }
    await _ready.future;
    _commands!.send(const _EncodeFinish());
    return _done.future;
  }

  /// Asks the worker to give up, and waits for it to say it has: killing it
  /// instead leaves the file handle open on Windows, the delete fails, and a
  /// half-written MP4 is left looking like a recording.
  @override
  Future<void> abort() async {
    if (_closed) return;
    _closed = true;
    _releaseWaiters(all: true);
    final worker = _worker;
    _worker = null;
    if (worker != null) {
      try {
        await _ready.future;
        _commands?.send(const _EncodeAbort());
        await _aborted.future;
      } on Object {
        // The worker never got as far as answering; there is nothing it can
        // have left behind either.
      }
      worker.kill(priority: Isolate.beforeNextEvent);
    }
    if (!_done.isCompleted) {
      _done.completeError(StateError('encode aborted'));
      // A caller who awaits `close()` still gets the error.
      _done.future.ignore();
    }
  }

  /// How many frames were handed over.
  int get frameCount => _frames;
}

/// Frames per second every recording is rendered and encoded at. Twelve, not
/// thirty: a terminal changes in bursts, so the extra frames cost a full encode
/// and show nothing new.
const int kRecordingFrameRate = 12;

const String kFrameEncoderIsolateName = 'karmashala.frame-encoder';

class _EncodeRequest {
  const _EncodeRequest({
    required this.reply,
    required this.format,
    required this.outputPath,
    required this.frameRate,
    required this.hardwareTransforms,
  });

  final SendPort reply;
  final RecordingFormat format;
  final String outputPath;
  final int frameRate;
  final bool hardwareTransforms;
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

class _EncodeFrameDone {
  const _EncodeFrameDone();
}

class _EncodeFinish {
  const _EncodeFinish();
}

class _EncodeAbort {
  const _EncodeAbort();
}

class _EncodeAborted {
  const _EncodeAborted();
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
    hardwareTransforms: request.hardwareTransforms,
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
          request.reply.send(const _EncodeFrameDone());
        case _EncodeFinish():
          request.reply.send(await encoder.finish());
          commands.close();
        case _EncodeAbort():
          encoder.abort();
          request.reply.send(const _EncodeAborted());
          commands.close();
      }
    } catch (error) {
      // Before reporting: a half-written MP4 must not be left looking finished.
      try {
        encoder.abort();
      } on Object {
        // The failure being reported is the one worth hearing.
      }
      request.reply.send(_EncodeFailure('$error'));
      commands.close();
    }
  }
}

/// The encoding itself — pure Dart, no `dart:ui`, so it runs wherever it is
/// put. Exposed so a test, or the device-recording path, can encode without
/// spawning an isolate.
class FrameEncoder {
  FrameEncoder({
    required this.format,
    required this.outputPath,
    this.frameRate = kRecordingFrameRate,
    bool hardwareTransforms = appHardwareTransforms,
    VideoEncoderOpener? openVideoEncoder,
  }) : _openVideoEncoder =
           openVideoEncoder ??
           (({
             required String path,
             required int width,
             required int height,
             required int frameRate,
           }) => openMediaFoundationEncoder(
             path: path,
             width: width,
             height: height,
             frameRate: frameRate,
             hardwareTransforms: hardwareTransforms,
           ));

  final RecordingFormat format;
  final String outputPath;
  final int frameRate;

  /// Injected so a test can encode without the operating system's encoder.
  final VideoEncoderOpener _openVideoEncoder;

  /// Opened on the first frame, because only a frame knows the picture size.
  VideoEncoder? _video;

  /// Octree rather than the package default's neural quantizer, and no dither:
  /// a terminal frame is a couple of dozen flat colours, and dithering the
  /// error it does not have reads as grain on glyph edges.
  late final img.GifEncoder _gif = img.GifEncoder(
    quantizerType: img.QuantizerType.octree,
    dither: img.DitherKernel.none,
    repeat: 0,
  );

  int _frames = 0;

  /// Created once, on the first frame, rather than per frame — a sequence is
  /// hundreds of them and each `createSync` is a syscall.
  late final Directory _sequenceDirectory = Directory(outputPath)
    ..createSync(recursive: true);

  void add(RgbaFrame frame) {
    if (format == RecordingFormat.mp4) {
      final video = _video ??= _openVideoEncoder(
        path: outputPath,
        width: frame.width,
        height: frame.height,
        frameRate: frameRate,
      );
      video.add(frame);
      _frames++;
      return;
    }
    final image = img.Image.fromBytes(
      width: frame.width,
      height: frame.height,
      bytes: frame.rgba.buffer,
      // A `ByteData.buffer` may be longer than the view onto it.
      bytesOffset: frame.rgba.offsetInBytes,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    switch (format) {
      case RecordingFormat.gif:
        // GIF delays are hundredths of a second and zero means "as fast as
        // the viewer likes" in most players, so clamp to one.
        final hundredths = (frame.hold.inMicroseconds / 10000).round();
        _gif.addFrame(image, duration: hundredths < 1 ? 1 : hundredths);
      case RecordingFormat.mp4:
        // Handled above, before the image was built.
        break;
      case RecordingFormat.pngSequence:
        final name = 'frame_${_frames.toString().padLeft(5, '0')}.png';
        File(
          p.join(_sequenceDirectory.path, name),
        ).writeAsBytesSync(img.encodePng(image));
    }
    _frames++;
  }

  /// Closes the encoder and removes anything half-written.
  void abort() {
    _video?.abort();
    _video = null;
  }

  Future<FrameSinkResult> finish() async {
    switch (format) {
      case RecordingFormat.mp4:
        final video = _video;
        if (video == null) throw StateError('no frames were encoded');
        return FrameSinkResult(
          path: outputPath,
          frames: _frames,
          bytes: video.finish(),
        );
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

/// The command that turns a rendered frame sequence into a Full HD MP4, also
/// written beside the frames so nobody has to retype it. `yuv420p` and the
/// even-dimension scale are what make it play outside VLC.
String ffmpegCommandFor(
  String frameDirectory, {
  int frameRate = kRecordingFrameRate,
}) =>
    'ffmpeg -framerate $frameRate '
    '-i "${p.join(frameDirectory, 'frame_%05d.png')}" '
    '-vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" '
    '-c:v libx264 -pix_fmt yuv420p -crf 20 '
    '"${p.join(frameDirectory, 'recording.mp4')}"';
