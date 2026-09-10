import 'package:path/path.dart' as p;

import 'package:agent_cli/process.dart' show formatBytes;
import 'device_target.dart';

/// Where one recording of [target] is written. **Neither half of the name may
/// carry a colon:** a wireless device is `192.168.1.24:37129`, and on Windows a
/// colon opens an alternate data stream — every write succeeds, the file is
/// empty.
String deviceRecordingPath({
  required DeviceTarget target,
  required String directory,
  required DateTime startedAt,
  required String extension,
}) => p.join(
  directory,
  '${target.fileSafeId}-${recordingStamp(startedAt)}.$extension',
);

/// `20260908-140307`: sortable, unambiguous, and legal on every filesystem.
String recordingStamp(DateTime at) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${at.year}${two(at.month)}${two(at.day)}-'
      '${two(at.hour)}${two(at.minute)}${two(at.second)}';
}

/// How long a recording ran, for a person reading one sentence.
String formatRecordingLength(Duration length) {
  String two(int value) => value.toString().padLeft(2, '0');
  final seconds = length.inSeconds % 60;
  final minutes = length.inMinutes % 60;
  final hours = length.inHours;
  if (hours > 0) return '${hours}h ${two(minutes)}m ${two(seconds)}s';
  if (minutes > 0) return '${minutes}m ${two(seconds)}s';
  return '${seconds}s';
}

/// The container a live-view recording is written in. Both hold the handset's
/// own H.264 with no re-encode; MP4 fixes the picture size in one sample entry,
/// so only MPEG-TS survives a rotation part way through.
enum DeviceRecordingContainer {
  mp4('mp4'),
  transportStream('ts');

  const DeviceRecordingContainer(this.extension);

  final String extension;
}

/// Which of the three things happened to a recording.
enum DeviceRecordingResult {
  /// A file was written and can be played.
  saved,

  /// Nothing arrived to record. There is no file.
  empty,

  /// The file could not be opened, or a write to it failed.
  failed,
}

/// What became of one recording, in a sentence the user can act on. Each outcome
/// has a different response, which one "recording failed" would collapse.
class DeviceRecordingOutcome {
  const DeviceRecordingOutcome({
    required this.result,
    required this.deviceId,
    required this.message,
    this.path,
  });

  /// A recording that ended with a playable file. [gaps] and [geometryChanges]
  /// each add a sentence, because both change what the file *is*.
  factory DeviceRecordingOutcome.saved({
    required DeviceTarget target,
    required String path,
    required int bytes,
    required Duration length,
    int gaps = 0,
    int geometryChanges = 0,
    DeviceRecordingContainer container = DeviceRecordingContainer.transportStream,
  }) {
    final sentences = <String>[
      'Recording saved to $path — ${formatBytes(bytes)} over '
          '${formatRecordingLength(length)}.',
      if (gaps > 0)
        'The live view was off for part of it, so the picture jumps '
            '${gaps == 1 ? 'once' : '$gaps times'}.',
      if (geometryChanges > 0)
        container == DeviceRecordingContainer.mp4
            // MP4 committed to the first size, so this is not a footnote about
            // the device — it is what the file now looks like.
            ? 'The device rotated during it. An MP4 keeps the size it started '
                  'with, so the picture after the rotation is stretched — '
                  'record to MPEG-TS if you need to rotate mid-recording.'
            : 'The device rotated during it, so the picture changes size '
                  'partway through.',
    ];
    return DeviceRecordingOutcome(
      result: DeviceRecordingResult.saved,
      deviceId: target.id,
      path: path,
      message: sentences.join(' '),
    );
  }

  /// A recording that stopped without being asked to, but did capture something.
  /// Its own sentence: the file ends where the device gave out, not where asked.
  factory DeviceRecordingOutcome.endedEarly({
    required DeviceTarget target,
    required String path,
    required int bytes,
    required Duration length,
    required String reason,
  }) => DeviceRecordingOutcome(
    result: DeviceRecordingResult.saved,
    deviceId: target.id,
    path: path,
    message:
        'Recording ended early: $reason. What was captured is saved to $path — '
        '${formatBytes(bytes)} over ${formatRecordingLength(length)}.',
  );

  /// A recording that captured no frame at all. The file is removed rather than
  /// left as a container header with no picture, which no player opens.
  factory DeviceRecordingOutcome.empty({
    required DeviceTarget target,
    required String reason,
  }) => DeviceRecordingOutcome(
    result: DeviceRecordingResult.empty,
    deviceId: target.id,
    message:
        'Nothing was recorded from ${target.id}: $reason. The empty file was '
        'removed.',
  );

  /// The destination could not be opened. Distinct from [writeFailed]: nothing
  /// was captured, so there is no partial file to keep.
  factory DeviceRecordingOutcome.failed({
    required DeviceTarget target,
    required String reason,
    String? path,
  }) => DeviceRecordingOutcome(
    result: DeviceRecordingResult.failed,
    deviceId: target.id,
    path: path,
    message: path == null
        ? 'Recording failed: $reason.'
        : 'Recording failed: $path could not be written — $reason.',
  );

  /// A write failed part way through — out of disk is the usual reason. What
  /// reached the file is kept and named: a truncated MPEG-TS still plays.
  factory DeviceRecordingOutcome.writeFailed({
    required DeviceTarget target,
    required String path,
    required String reason,
    required int bytes,
  }) => DeviceRecordingOutcome(
    result: DeviceRecordingResult.failed,
    deviceId: target.id,
    path: path,
    message:
        'Recording stopped: writing to $path failed — $reason. '
        '${formatBytes(bytes)} was saved before it.',
  );

  final DeviceRecordingResult result;

  /// The device it was of — [DeviceTarget.id], never the file-safe spelling.
  final String deviceId;

  /// The file, when there is one to point at. Null for [
  /// DeviceRecordingResult.empty] and for a destination that never opened.
  final String? path;

  final String message;
}

/// What the recorder is doing.
sealed class DeviceRecordingState {
  const DeviceRecordingState();
}

/// Nothing is being recorded. [last] is what the previous one came to, kept so
/// the user who switched panes mid-recording still finds out how it ended.
class DeviceRecordingIdle extends DeviceRecordingState {
  const DeviceRecordingIdle([this.last]);

  final DeviceRecordingOutcome? last;
}

/// A recording is running. [receiving] is false while the recorder has no
/// source — still open and still the user's to stop, but not capturing. It
/// carries no running byte or frame count: that would rebuild the banner sixty
/// times a second for a number nobody reads.
class DeviceRecordingActive extends DeviceRecordingState {
  const DeviceRecordingActive({
    required this.target,
    required this.path,
    required this.startedAt,
    this.receiving = true,
    this.gaps = 0,
    this.geometryChanges = 0,
  });

  final DeviceTarget target;
  final String path;
  final DateTime startedAt;

  final bool receiving;

  /// How many times the source went away and came back.
  final int gaps;

  /// How many times the device changed video geometry — a rotation, or a
  /// resize.
  final int geometryChanges;

  DeviceRecordingActive copyWith({
    bool? receiving,
    int? gaps,
    int? geometryChanges,
  }) => DeviceRecordingActive(
    target: target,
    path: path,
    startedAt: startedAt,
    receiving: receiving ?? this.receiving,
    gaps: gaps ?? this.gaps,
    geometryChanges: geometryChanges ?? this.geometryChanges,
  );
}
