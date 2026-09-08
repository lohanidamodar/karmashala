import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../../core/media/media_foundation.dart';
import '../../../core/media/video_writer.dart';

/// One encoded frame off a device, with the stream state it was produced under.
///
/// The geometry and the SPS/PPS travel with the frame rather than with the
/// stream because a rotation changes both mid-recording, and a container that
/// fixes them (MP4) has to know which ones it committed to.
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
///
/// Small on purpose. The only thing a recorder needs of a destination is that
/// it takes bytes, says when a write to it failed, and reports how much it
/// ended up holding — and a test that had to stand in for `IOSink` would have
/// to implement `StringSink` as well, for no gain.
abstract interface class RecordingSink {
  /// Hands [bytes] over. Does not wait for them: a live view produces frames
  /// faster than a disk acknowledges them, and awaiting each one would put the
  /// disk in front of the picture.
  void add(List<int> bytes);

  /// Errors when a write failed, and never completes normally before [close].
  ///
  /// This is the out-of-disk path. [add] cannot report it — the write has not
  /// happened yet when it returns — so the failure arrives here instead, and
  /// arrives as an event rather than as something a caller has to go and ask
  /// about.
  Future<void> get done;

  /// Flushes, closes, and answers how many bytes the destination holds.
  ///
  /// The size is read back rather than counted on the way in, so a partial
  /// write is reported as what reached the disk rather than as what was
  /// offered to it.
  Future<int> close();
}

/// A [RecordingSink] writing to a file on this machine.
class FileRecordingSink implements RecordingSink {
  FileRecordingSink._(this._file, this._sink);

  /// Creates [path]'s directory if it is missing and opens the file.
  ///
  /// Throws whatever the filesystem throws — a read-only location, a name the
  /// platform refuses, a full disk — and the caller turns that into the
  /// "destination could not be opened" outcome, which is a different sentence
  /// from a write that failed part way through.
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

/// Writes a device recording as MP4, muxing the handset's own H.264.
///
/// **No re-encode.** The frames arrive already encoded, so this is a container
/// change: measured byte-identical in `video_writer_test.dart`.
///
/// The picture size and the SPS/PPS come from the **first** access unit and are
/// then fixed, because that is what MP4 is: one sample entry for the track. A
/// rotation part way through therefore keeps the first size and the later part
/// is stretched — which is why MPEG-TS is still offered, and why the outcome
/// says so when it happens.
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

/// The rate an MP4 of a device declares.
///
/// scrcpy's own timestamps decide each frame's real duration; this is only the
/// track's nominal rate, and a container needs one.
const int kDeviceRecordingFrameRate = 30;
