import 'dart:typed_data';

import 'frame_sink.dart';

/// One already-encoded H.264 access unit, Annex-B, as a container needs it.
class EncodedVideoFrame {
  const EncodedVideoFrame({
    required this.bytes,
    required this.at,
    required this.keyframe,
  });

  final Uint8List bytes;

  /// Presentation time from the start of the recording.
  final Duration at;
  final bool keyframe;
}

/// Turns RGBA frames into a finished, playable video file.
///
/// The counterpart of [FrameSink] on the far side of the encode: frames in,
/// a file on disk out, and the encoder itself is somebody else's problem.
abstract interface class VideoEncoder {
  void add(RgbaFrame frame);

  /// Closes the container and returns the file's length in bytes.
  int finish();

  /// Gives up and removes the part-written file. Safe after [finish].
  void abort();
}

/// Puts already-encoded H.264 into a container without re-encoding it.
///
/// The device path arrives here: scrcpy hands over the handset's own H.264, so
/// a recording needs a container and nothing else.
abstract interface class VideoRemuxer {
  void add(EncodedVideoFrame frame);
  int finish();
  void abort();
}

typedef VideoEncoderOpener =
    VideoEncoder Function({
      required String path,
      required int width,
      required int height,
      required int frameRate,
    });

typedef VideoRemuxerOpener =
    VideoRemuxer Function({
      required String path,
      required int width,
      required int height,
      required int frameRate,
      required Uint8List sequenceHeader,
    });

/// Whether this host can write an MP4, and what was actually seen.
///
/// §19: a format is offered because an encoder was found, never because the
/// platform name looked right. [detail] is shown to the user as-is.
class VideoSupport {
  const VideoSupport.available(this.detail) : available = true;
  const VideoSupport.unavailable(this.detail) : available = false;

  final bool available;

  /// Names the encoder when there is one; says which platform and what to use
  /// instead when there is not.
  final String detail;

  @override
  String toString() => 'VideoSupport(${available ? 'yes' : 'no'}: $detail)';
}
