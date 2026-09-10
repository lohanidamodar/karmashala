import 'dart:async';
import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:karmashala_core/logging.dart';
import 'package:agent_cli/process.dart';
import 'device_ports.dart';
import '../../devices.dart';
import 'ios_device_providers.dart';

/// The folder recordings are written to, under the app's support directory.
/// Not the Desktop (that is a screenshot) and not temp, which the OS deletes.
const String kDeviceRecordingsFolder = 'recordings';

/// What an MPEG-TS recording of an Android live view is called: `.ts`, not
/// `.mp4` — see `DeviceRecordingController.startLiveViewRecording`.
const String kTransportStreamExtension = 'ts';

/// Opens an MP4 destination. Injected so a test needs no OS muxer.
typedef Mp4WriterOpener = Mp4RecordingWriter Function(String path);

final mp4WriterOpenerProvider = Provider<Mp4WriterOpener>(
  (ref) => Mp4RecordingWriter.open,
);

/// What `simctl io … recordVideo` writes: a QuickTime movie.
const String kQuickTimeExtension = 'mov';

/// Opens a destination for a recording. Injected so a test can hand the
/// recorder a list instead of a disk.
typedef RecordingSinkOpener = Future<RecordingSink> Function(String path);

/// The directory recordings go in, created if it is missing — `simctl` writes
/// its own file and would otherwise need a second way to make the folder.
final deviceRecordingDirectoryProvider = Provider<Future<String> Function()>(
  (ref) => () async {
    final directory = Directory(
      p.join(
        (await ref.read(deviceDataDirectoryProvider)()).path,
        kDeviceRecordingsFolder,
      ),
    );
    await directory.create(recursive: true);
    return directory.path;
  },
);

final recordingSinkOpenerProvider = Provider<RecordingSinkOpener>(
  (ref) => FileRecordingSink.open,
);

/// A running Android live view, offered to the recorder as a source of frames.
class LiveViewRecordingSource {
  const LiveViewRecordingSource({
    required this.target,
    required this.openTransportStream,
    required this.openAccessUnits,
    required this.geometryChanges,
  });

  final DeviceTarget target;

  /// See `DeviceStreamSession.openTransportStream`.
  final MediaStreamFactory openTransportStream;

  /// The same frames unmuxed, for the MP4 container to mux itself.
  final AccessUnitStreamFactory openAccessUnits;

  /// The session's rotations and resizes, counted so the file can say it
  /// changes size partway through.
  final Stream<DeviceScreenSize> geometryChanges;
}

final deviceRecordingProvider =
    NotifierProvider<DeviceRecordingController, DeviceRecordingState>(
      DeviceRecordingController.new,
    );

/// The one screen recording at a time — a second would be a side effect with
/// nothing on screen — held in a provider, since a pane switch would strand it.
class DeviceRecordingController extends Notifier<DeviceRecordingState> {
  /// Mirrors [state] so `ref.onDispose` has something to read — reading
  /// `state` inside a life-cycle callback is forbidden.
  DeviceRecordingState _current = const DeviceRecordingIdle();

  LiveViewRecordingSource? _source;

  RecordingSink? _sink;
  Mp4RecordingWriter? _mp4;
  DeviceRecordingContainer _container = DeviceRecordingContainer.transportStream;
  StreamSubscription<void>? _video;
  StreamSubscription<DeviceScreenSize>? _sizes;
  ProcessHandle? _process;

  /// Events off the transport stream. The first is the container tables, so
  /// anything after it is how "nothing recorded" is told from "a header".
  int _chunks = 0;
  int _gaps = 0;
  int _geometryChanges = 0;

  /// Set the moment a finish begins, so the source ending, a failed write and
  /// Stop cannot each write an outcome for the same recording.
  bool _finishing = false;

  /// Whether chunks still belong in the file: the subscription is dropped
  /// rather than awaited (see [_finish]), so one can arrive after the close.
  bool _accepting = false;

  static final AppLogger _log = AppLogger.named('device-recording');

  @override
  DeviceRecordingState build() {
    // The app is closing: close the file, and write no outcome nobody reads.
    ref.onDispose(() => unawaited(_abandon()));
    return _current = const DeviceRecordingIdle();
  }

  void _set(DeviceRecordingState next) => state = _current = next;

  /// Tells the recorder that [source]'s live view is running. Called on every
  /// session start, so a recording that lost its frames picks them up again.
  void offerLiveView(LiveViewRecordingSource source) {
    _source = source;
    final active = _current;
    if (active is! DeviceRecordingActive) return;
    // A live view of some other device is not this recording's source. Letting
    // it become one would splice two devices into one file.
    if (active.target.id != source.target.id) return;
    if (_video != null) return;
    _gaps += 1;
    _attach(source);
    _set(active.copyWith(receiving: true, gaps: _gaps));
  }

  /// Records the live view the pane last offered. `.ts` by default: the app
  /// already holds the encoded H.264 and has no muxer but its own `TsMuxer`.
  Future<void> startLiveViewRecording({
    DeviceRecordingContainer container =
        DeviceRecordingContainer.transportStream,
  }) async {
    if (_current is DeviceRecordingActive) return;
    final source = _source;
    if (source == null) return;

    final startedAt = ref.read(deviceClockProvider).nowUtc();
    final String path;
    RecordingSink? sink;
    Mp4RecordingWriter? mp4;
    try {
      path = deviceRecordingPath(
        target: source.target,
        directory: await ref.read(deviceRecordingDirectoryProvider)(),
        startedAt: startedAt,
        extension: container.extension,
      );
      if (container == DeviceRecordingContainer.mp4) {
        // The container itself opens on the first frame, when the picture size
        // is known; nothing touches the disk before then.
        mp4 = ref.read(mp4WriterOpenerProvider)(path);
      } else {
        sink = await ref.read(recordingSinkOpenerProvider)(path);
      }
    } on Object catch (error, stack) {
      _log.warning('A recording of ${source.target.id} would not open', error, stack);
      _set(
        DeviceRecordingIdle(
          DeviceRecordingOutcome.failed(
            target: source.target,
            reason: '$error',
          ),
        ),
      );
      return;
    }

    _sink = sink;
    _mp4 = mp4;
    _container = container;
    _chunks = 0;
    _gaps = 0;
    _geometryChanges = 0;
    _finishing = false;
    _accepting = true;
    _watchForWriteFailure(sink?.done ?? mp4!.done);
    _set(
      DeviceRecordingActive(
        target: source.target,
        path: path,
        startedAt: startedAt,
      ),
    );
    _attach(source);
  }

  /// Records a booted simulator with `simctl io … recordVideo`: its live view
  /// is MJPEG, not an encoded stream. macOS only, and never watched working.
  Future<void> startSimulatorRecording(SimulatorTarget target) async {
    if (_current is DeviceRecordingActive) return;
    final simctl = ref.read(simctlServiceProvider);
    if (simctl == null) return;

    final startedAt = ref.read(deviceClockProvider).nowUtc();
    final String path;
    final ProcessHandle process;
    try {
      path = deviceRecordingPath(
        target: target,
        directory: await ref.read(deviceRecordingDirectoryProvider)(),
        startedAt: startedAt,
        extension: kQuickTimeExtension,
      );
      process = await simctl.startRecording(target.id, path);
    } on Object catch (error, stack) {
      _log.warning('A recording of ${target.id} would not start', error, stack);
      _set(
        DeviceRecordingIdle(
          DeviceRecordingOutcome.failed(target: target, reason: '$error'),
        ),
      );
      return;
    }

    _process = process;
    _chunks = 0;
    _gaps = 0;
    _geometryChanges = 0;
    _finishing = false;
    _set(
      DeviceRecordingActive(
        target: target,
        path: path,
        startedAt: startedAt,
      ),
    );
    // `recordVideo` only ends when it is asked to, so an exit of its own is an
    // event: the simulator shut down under it, or simctl refused the request.
    unawaited(
      process.exitCode
          .then((code) => _finish(endedEarly: _simctlExitReason(code)))
          .catchError((Object _) {}),
    );
  }

  /// Ends the recording and writes its outcome. Idempotent.
  Future<void> stop() => _finish();

  /// Clears the last outcome once the user has read it — never on a timer:
  /// the message names a file on disk the user may come back for.
  void dismiss() {
    if (_current is DeviceRecordingIdle) _set(const DeviceRecordingIdle());
  }

  void _attach(LiveViewRecordingSource source) {
    final sink = _sink;
    final mp4 = _mp4;
    if (sink == null && mp4 == null) return;
    // Two shapes, because the containers take different things: MPEG-TS is
    // already muxed upstream, MP4 muxes the access units here.
    _video = mp4 != null
        ? source.openAccessUnits().listen(
            (unit) {
              if (!_accepting) return;
              _chunks += 1;
              mp4.add(unit);
            },
            onDone: _sourceEnded,
            onError: (Object _) => _sourceEnded(),
            cancelOnError: true,
          )
        : source.openTransportStream().listen(
            (chunk) {
              if (!_accepting) return;
              _chunks += 1;
              sink!.add(chunk);
            },
            onDone: _sourceEnded,
            onError: (Object _) => _sourceEnded(),
            cancelOnError: true,
          );
    _sizes = source.geometryChanges.listen((_) {
      _geometryChanges += 1;
      final active = _current;
      if (active is DeviceRecordingActive) {
        _set(active.copyWith(geometryChanges: _geometryChanges));
      }
    });
  }

  /// The live view stopped. The recording is **not** finished here: it stays
  /// open and the user's to stop, or a pane switch would silently drop it.
  void _sourceEnded() {
    final video = _video;
    final sizes = _sizes;
    _video = null;
    _sizes = null;
    _source = null;
    unawaited(video?.cancel());
    unawaited(sizes?.cancel());
    final active = _current;
    if (active is DeviceRecordingActive && active.receiving) {
      _set(active.copyWith(receiving: false));
    }
  }

  /// Out of disk, and everything else the filesystem only discovers on the
  /// write itself. It arrives as an event rather than being polled for.
  void _watchForWriteFailure(Future<void> done) {
    unawaited(
      done.then(
        (_) {},
        onError: (Object error) => unawaited(_finish(writeFailure: error)),
      ),
    );
  }

  Future<void> _finish({Object? writeFailure, String? endedEarly}) async {
    final active = _current;
    if (_finishing || active is! DeviceRecordingActive) return;
    _finishing = true;
    _accepting = false;

    final video = _video;
    final sizes = _sizes;
    final sink = _sink;
    final mp4 = _mp4;
    final process = _process;
    _video = null;
    _sizes = null;
    _sink = null;
    _mp4 = null;
    _process = null;
    // Dropped, not awaited: cancelling the `async*` transport stream does not
    // complete until it next yields, which on an idle device is never.
    unawaited(video?.cancel());
    unawaited(sizes?.cancel());
    // The interrupt, not a kill: see `SimctlService.startRecording`.
    if (process != null && endedEarly == null) await process.interrupt();

    var bytes = 0;
    Object? closeError = writeFailure;
    if (sink != null) {
      try {
        bytes = await sink.close();
      } on Object catch (error) {
        closeError ??= error;
      }
    }
    if (mp4 != null) {
      try {
        bytes = await mp4.close();
      } on Object catch (error) {
        closeError ??= error;
        mp4.abort();
      }
    }
    if (bytes == 0) bytes = await _sizeOf(active.path);

    final length = ref.read(deviceClockProvider).nowUtc().difference(active.startedAt);
    // A transport stream whose only event was the container tables holds no
    // picture, however many bytes. An MP4 counts access units, so one is real.
    final noPicture =
        bytes == 0 ||
        (sink != null && _chunks <= 1) ||
        (mp4 != null && _chunks == 0);

    if (closeError != null && bytes > 0) {
      _set(
        DeviceRecordingIdle(
          DeviceRecordingOutcome.writeFailed(
            target: active.target,
            path: active.path,
            reason: '$closeError',
            bytes: bytes,
          ),
        ),
      );
      return;
    }
    if (closeError != null) {
      await _discard(active.path);
      _set(
        DeviceRecordingIdle(
          DeviceRecordingOutcome.failed(
            target: active.target,
            reason: '$closeError',
            path: active.path,
          ),
        ),
      );
      return;
    }
    if (noPicture) {
      await _discard(active.path);
      _set(
        DeviceRecordingIdle(
          DeviceRecordingOutcome.empty(
            target: active.target,
            reason: endedEarly ?? 'no frames arrived',
          ),
        ),
      );
      return;
    }
    _set(
      DeviceRecordingIdle(
        endedEarly == null
            ? DeviceRecordingOutcome.saved(
                target: active.target,
                path: active.path,
                bytes: bytes,
                length: length,
                gaps: active.gaps,
                geometryChanges: active.geometryChanges,
                container: _container,
              )
            : DeviceRecordingOutcome.endedEarly(
                target: active.target,
                path: active.path,
                bytes: bytes,
                length: length,
                reason: endedEarly,
              ),
      ),
    );
  }

  /// Releases what a recording holds without writing an outcome — the app is
  /// going away, and nobody is left to read one.
  Future<void> _abandon() async {
    final video = _video;
    final sizes = _sizes;
    final sink = _sink;
    final mp4 = _mp4;
    final process = _process;
    _video = null;
    _sizes = null;
    _sink = null;
    _mp4 = null;
    _process = null;
    _finishing = true;
    _accepting = false;
    unawaited(video?.cancel());
    unawaited(sizes?.cancel());
    await process?.interrupt();
    try {
      await sink?.close();
      await mp4?.close();
    } on Object {
      // Nothing left to tell.
    }
  }

  static String _simctlExitReason(int code) => code == 0
      ? 'the recording stopped on its own'
      : 'simctl recordVideo exited with $code';

  Future<int> _sizeOf(String path) async {
    try {
      return await File(path).length();
    } on Object {
      // Never written, or gone: zero means "no file" to the caller.
      return 0;
    }
  }

  Future<void> _discard(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on Object {
      // A header nobody can play is a smaller problem than a failed delete.
    }
  }
}
