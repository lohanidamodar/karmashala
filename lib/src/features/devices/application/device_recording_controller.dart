import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/logging/app_logger.dart';
import '../../../core/paths/app_support_directory.dart';
import '../../../core/process/process_handle.dart';
import '../../../core/util/clock_provider.dart';
import '../data/loopback_media_server.dart' show MediaStreamFactory;
import '../data/recording_sink.dart';
import '../domain/device_input.dart';
import '../domain/device_recording.dart';
import '../domain/device_target.dart';
import 'ios_device_providers.dart';

/// The folder recordings are written to, under the app's support directory.
///
/// Not the Desktop, which is where a *screenshot* goes: a screenshot is a
/// thing you are about to paste somewhere, and a screen recording is a file
/// you keep. Not the system temp directory either — the OS deletes that, and
/// this is something the user asked for by name.
const String kDeviceRecordingsFolder = 'recordings';

/// What an MPEG-TS recording of an Android live view is called.
///
/// **`.ts`, not `.mp4`, and that is the honest name for what is in it.** See
/// `DeviceRecordingController.startLiveViewRecording`.
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

/// The directory recordings go in, created if it is missing.
///
/// It creates rather than only naming, so the one caller that does not write
/// through a [RecordingSink] — the simulator, where `simctl` writes the file
/// itself — does not need a second way to make a folder.
final deviceRecordingDirectoryProvider = Provider<Future<String> Function()>(
  (ref) => () async {
    final directory = Directory(
      p.join((await appSupportDirectory()).path, kDeviceRecordingsFolder),
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

/// The one screen recording this app will run at a time.
///
/// **One at a time on purpose.** The pane shows one device, and a second
/// recording would be a long-lived side effect with nothing on screen
/// representing it — the failure this whole feature is shaped around.
///
/// It is a provider and not pane state for the reason `androidLiveViewProvider`
/// is: the side panel unmounts the device pane whenever it switches surface,
/// and a recording that vanished with it would leave a half-written file and no
/// way to ask about it.
class DeviceRecordingController extends Notifier<DeviceRecordingState> {
  /// Mirrors [state] so `ref.onDispose` has something to read — reading
  /// `state` inside a life-cycle callback is forbidden.
  DeviceRecordingState _current = const DeviceRecordingIdle();

  /// The live view the pane last told us about, or null when there is none to
  /// record.
  LiveViewRecordingSource? _source;

  RecordingSink? _sink;
  Mp4RecordingWriter? _mp4;
  DeviceRecordingContainer _container = DeviceRecordingContainer.transportStream;
  StreamSubscription<void>? _video;
  StreamSubscription<DeviceScreenSize>? _sizes;
  ProcessHandle? _process;

  /// Events taken off the transport stream. The first is the container tables;
  /// anything at all after it means a frame arrived, which is how "nothing was
  /// recorded" is told apart from "a few hundred bytes of header".
  int _chunks = 0;
  int _gaps = 0;
  int _geometryChanges = 0;

  /// Set the moment a finish begins, so the source ending, a failed write and
  /// the user pressing Stop cannot each write an outcome for the same
  /// recording.
  bool _finishing = false;

  /// Whether chunks off the transport stream still belong in the file.
  ///
  /// Needed because the recorder's subscription is **dropped rather than
  /// awaited** — see [_finish] — so a frame already in flight can arrive after
  /// the destination has been closed.
  bool _accepting = false;

  static final AppLogger _log = AppLogger.named('device-recording');

  @override
  DeviceRecordingState build() {
    // The app is closing, or the container is being torn down. The file is
    // closed rather than left open, and no outcome is written: there is
    // nobody left to read one.
    ref.onDispose(() => unawaited(_abandon()));
    return _current = const DeviceRecordingIdle();
  }

  void _set(DeviceRecordingState next) => state = _current = next;

  /// Tells the recorder that [source]'s live view is running.
  ///
  /// Called on every session start, not only when a recording is wanted. A
  /// recording that lost its frames when the pane unmounted picks them up here
  /// when the pane comes back, which is why this is separate from
  /// [startLiveViewRecording].
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

  /// Records the live view the pane last offered.
  ///
  /// ## Why the file is a `.ts` and not a `.mp4`
  ///
  /// This app does not run the scrcpy client: it pushes `scrcpy-server`, parses
  /// the protocol itself, and already holds the **encoded H.264 elementary
  /// stream** the picture is made of. So a recording needs no second capture
  /// and no re-encode — it needs a container, and there is no ffmpeg and no
  /// native muxer here. What there is, written for the live view, is
  /// `TsMuxer`: a pure-Dart MPEG-TS muxer already carrying scrcpy's per-frame
  /// timestamps, already flagging its own discontinuities, and already
  /// demuxable by libmpv's FFmpeg. So this writes the bytes the picture is
  /// already made of, straight to disk.
  ///
  /// The cost is the extension. `.ts` opens in VLC, mpv and anything FFmpeg is
  /// behind, and `ffmpeg -i x.ts -c copy x.mp4` remuxes it losslessly with no
  /// re-encode — but it is not the file every player on the machine will
  /// double-click. Saying so is the point: an `.mp4` that does not play would
  /// be worse.
  ///
  /// MPEG-TS also happens to be the container that survives what this stream
  /// does. A rotation re-sends SPS/PPS mid-stream and changes the picture's
  /// size; MP4 fixes both in one sample entry, and a rotation would need a
  /// second track.
  ///
  /// ## And why there is an MP4 now anyway
  ///
  /// [DeviceRecordingContainer.mp4] muxes the *same* frames through the
  /// operating system's MP4 sink — still no re-encode, measured byte-identical
  /// — so the file every player double-clicks costs nothing but the container.
  /// The rotation limit above is real and is what the outcome says when one
  /// happens; MPEG-TS stays on offer for exactly that.
  ///
  /// [container] defaults to MPEG-TS so it is never chosen by omission. The
  /// surfaces name what they want.
  Future<void> startLiveViewRecording({
    DeviceRecordingContainer container =
        DeviceRecordingContainer.transportStream,
  }) async {
    if (_current is DeviceRecordingActive) return;
    final source = _source;
    if (source == null) return;

    final startedAt = ref.read(clockProvider).nowUtc();
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

  /// Records a booted simulator with `simctl io <udid> recordVideo`.
  ///
  /// A different route from the Android one, and it has to be: this app has no
  /// video stream of a simulator to tee — the live view is WebDriverAgent's
  /// MJPEG, which is a screenshot feed and not an encoded video — while
  /// `simctl` records the display itself and writes a real QuickTime movie.
  ///
  /// **macOS only, and unverified.** `simctlServiceProvider` is null on any
  /// other host, which is the same gate every other simulator verb uses, so
  /// this returns without doing anything there. Nothing below has been watched
  /// producing a file: it was written and tested on Windows.
  Future<void> startSimulatorRecording(SimulatorTarget target) async {
    if (_current is DeviceRecordingActive) return;
    final simctl = ref.read(simctlServiceProvider);
    if (simctl == null) return;

    final startedAt = ref.read(clockProvider).nowUtc();
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

  /// Clears the last outcome, once the user has read it.
  ///
  /// It is not cleared on a timer and not cleared by starting something else:
  /// the message names a file on disk, and a user who switched panes has to be
  /// able to come back and still find out where it went.
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

  /// The live view stopped: the pane was switched away from, the stream was
  /// restarted, or the device went.
  ///
  /// The recording is **not** finished here. It stays open, visible and the
  /// user's to stop — the whole reason it lives in a provider — and says it is
  /// no longer capturing. Ending it would silently drop a recording on a pane
  /// switch, and the file is what the user asked for.
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
    // **Dropped, not awaited.** The transport stream is an `async*` generator
    // suspended on the session's frame controller, and cancelling one of those
    // does not complete until the generator next reaches a yield — which on an
    // idle device is never, because scrcpy encodes on change and a phone
    // nobody is touching sends nothing for minutes. Awaiting it would hang
    // Stop on exactly the device that is easiest to leave recording.
    // [_accepting] is what keeps a late chunk out of a closed file.
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

    final length = ref.read(clockProvider).nowUtc().difference(active.startedAt);
    // A transport stream whose only event was the container tables holds no
    // picture, however many bytes that is. An MP4 counts access units, so one
    // of those is already a picture.
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
  /// going away, and a state nobody will read is not worth the risk of
  /// touching a disposed provider.
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
      // Never written, or gone. Zero here means "no file", which the caller
      // turns into "nothing was recorded" rather than a length of zero.
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
