import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala_media/media.dart';

/// One encoded frame off a device, with the stream state it was produced under.
/// The geometry and the SPS/PPS travel with the frame because a rotation changes
/// both mid-recording, and MP4 has to know which ones it committed to.
class DeviceAccessUnit {
  const DeviceAccessUnit({
    required this.bytes,
    required this.ptsUs,
    required this.keyframe,
    required this.width,
    required this.height,
    required this.sequenceHeader,
  });

  /// Annex-B, SPS/PPS already prepended on a keyframe.
  final Uint8List bytes;
  final int ptsUs;
  final bool keyframe;
  final int width;
  final int height;

  /// Annex-B SPS/PPS on its own, empty until the device has sent it.
  final Uint8List sequenceHeader;
}

typedef AccessUnitStreamFactory = Stream<DeviceAccessUnit> Function();

/// Where a screen recording's bytes go: a file in the app, a list in a test.
/// Small on purpose — a stand-in for `IOSink` would have to be a `StringSink`.
abstract interface class RecordingSink {
  /// Hands [bytes] over. Does not wait for them: a live view produces frames
  /// faster than a disk acknowledges them, and awaiting each one would put the
  /// disk in front of the picture.
  void add(List<int> bytes);

  /// Errors when a write failed, and never completes normally before [close].
  /// The out-of-disk path: [add] returns before the write has happened.
  Future<void> get done;

  /// Flushes, closes, and answers how many bytes the destination holds. Read
  /// back rather than counted in, so a partial write reports what reached disk.
  Future<int> close();
}

/// A [RecordingSink] writing to a file on this machine.
class FileRecordingSink implements RecordingSink {
  FileRecordingSink._(this._file, this._sink);

  /// Creates [path]'s directory if it is missing and opens the file. Throws
  /// whatever the filesystem throws: "could not be opened" is a different
  /// sentence from a write that failed part way through.
  static Future<RecordingSink> open(String path) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    return FileRecordingSink._(file, file.openWrite());
  }

  final File _file;
  final IOSink _sink;

  @override
  void add(List<int> bytes) => _sink.add(bytes);

  @override
  Future<void> get done => _sink.done;

  @override
  Future<int> close() async {
    await _sink.flush();
    await _sink.close();
    return _file.length();
  }
}

/// Writes a device recording as MP4, muxing the handset's own H.264 with **no
/// re-encode**. The picture size and the SPS/PPS come from the **first** access
/// unit and are then fixed — that is what MP4 is — so a rotation part way
/// through leaves the rest stretched, which is why MPEG-TS is still offered.
class Mp4RecordingWriter {
  Mp4RecordingWriter._(this.path, this._open);

  /// Injected so a test can record without the operating system's muxer.
  static Mp4RecordingWriter open(
    String path, {
    VideoRemuxerOpener openRemuxer = openMediaFoundationRemuxer,
  }) => Mp4RecordingWriter._(path, openRemuxer);

  final String path;
  final VideoRemuxerOpener _open;
  final _done = Completer<void>();
  VideoRemuxer? _remuxer;
  int _units = 0;

  /// How many access units reached the file. Zero means no picture.
  int get units => _units;

  /// The size the container committed to, or null before the first frame.
  ({int width, int height})? get committedSize => _size;
  ({int width, int height})? _size;

  void add(DeviceAccessUnit unit) {
    if (_done.isCompleted) return;
    try {
      final remuxer =
          _remuxer ??= _open(
            path: path,
            width: unit.width,
            height: unit.height,
            frameRate: kDeviceRecordingFrameRate,
            sequenceHeader: unit.sequenceHeader,
          );
      _size ??= (width: unit.width, height: unit.height);
      remuxer.add(
        EncodedVideoFrame(
          bytes: unit.bytes,
          at: Duration(microseconds: unit.ptsUs),
          keyframe: unit.keyframe,
        ),
      );
      _units += 1;
    } on Object catch (error, stack) {
      // The same shape as a failed disk write: reported as an event, once.
      if (!_done.isCompleted) _done.completeError(error, stack);
    }
  }

  Future<void> get done => _done.future;

  Future<int> close() async {
    final remuxer = _remuxer;
    if (remuxer == null) {
      // Nothing arrived, so there is no container to close and no file to
      // report. The caller turns a zero into "nothing was recorded".
      return 0;
    }
    _remuxer = null;
    try {
      return remuxer.finish();
    } on Object {
      remuxer.abort();
      return 0;
    }
  }

  /// Drops the part-written file: nothing would open it.
  void abort() {
    _remuxer?.abort();
    _remuxer = null;
  }
}

/// The rate an MP4 of a device declares. scrcpy's own timestamps decide each
/// frame's real duration; this is only the nominal rate a container needs.
const int kDeviceRecordingFrameRate = 30;
