import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:agent_cli/process.dart';
import '../domain/device_input.dart';
import 'adb_output_parsing.dart';
import 'adb_service.dart';
import 'scrcpy_control.dart';
import 'scrcpy_protocol.dart';
import 'recording_sink.dart';
import 'loopback_media_server.dart';
import 'ts_muxer.dart';

/// scrcpy release this app deploys. The jar and the version string handed to
/// `app_process` must match exactly or the server refuses to start.
const String kScrcpyVersion = '4.1';

/// Where the server jar is bundled in the Flutter asset bundle.
const String kScrcpyServerAsset = 'assets/scrcpy/scrcpy-server';

/// Everything this app pushes to a device starts with this, and nothing else
/// does: `reapOrphans` matches on it, so it must not match plain scrcpy's jar.
const String kScrcpyJarPathPrefix = '/data/local/tmp/karmashala-scrcpy-server';

/// The jar path for one session. **Per session**, not per app: scrcpy-server 4.1
/// unlinks its own jar as it starts, so a shared path breaks the next attempt.
String scrcpyJarPathFor(String scid) => '$kScrcpyJarPathPrefix-$scid.jar';

/// What a **host-side** staged jar is called, before it is pushed. Unique per
/// start: a fixed name let a test's 4-byte dummy jar reach a live phone.
const String kScrcpyHostJarPrefix = 'karmashala-scrcpy-server-';

String scrcpyHostJarName(String token) =>
    '$kScrcpyHostJarPrefix$kScrcpyVersion-$token.jar';

/// How long a staged jar may sit before a later start treats it as debris. Age
/// rather than ownership: no process can tell which of these another still needs.
const Duration kStagedJarLifetime = Duration(hours: 1);

/// Supplies the scrcpy server jar bytes (the Flutter asset in the app, a
/// fixture in tests).
typedef ScrcpyServerBytes = Future<Uint8List> Function();

/// Parses the port adb allocated for `adb forward tcp:0 …`. Port 0 avoids a bind
/// race and Windows' reserved ranges; scrcpy's 27183 was unavailable here.
int? parseForwardedPort(String output) {
  for (final line in output.split(RegExp(r'[\r\n]+'))) {
    final port = int.tryParse(line.trim());
    if (port != null && port > 0) return port;
  }
  return null;
}

/// Timestamps of the newest frame in flight, all in microseconds. [ptsUs] is the
/// **device's** monotonic clock at capture; [arrivalUs] is the host wall clock.
class LiveFrameMark {
  int frames = 0;
  int ptsUs = 0;
  int arrivalUs = 0;
  int? basePtsUs;

  /// Host clock when the newest frame was handed to the HTTP response, i.e.
  /// when it stopped being ours and became the player's problem.
  int writtenUs = 0;

  /// Host clock when the user last asked the device to do something.
  int lastInputUs = 0;

  /// Interactions the device has not answered with a frame.
  int unansweredInputs = 0;

  /// Records that the user asked the device for something. Counts **interactions,
  /// not events**: a drag within [kInputBurst] is one, not fifty unanswered.
  void noteInput([int? nowUs]) {
    final now = nowUs ?? DateTime.now().microsecondsSinceEpoch;
    if (lastInputUs == 0 || now - lastInputUs > kInputBurst.inMicroseconds) {
      unansweredInputs += 1;
    }
    lastInputUs = now;
  }

  /// The device answered: a frame arrived.
  void noteAnswered() => unansweredInputs = 0;

  /// Whether the picture is on screen. See [StreamClocks.watching].
  bool watching = true;
}

/// How close together two input events have to be to count as one interaction.
const Duration kInputBurst = Duration(milliseconds: 250);

/// What the live view is doing, as far as the app can tell from outside the
/// video player.
enum DeviceStreamState {
  /// Connected; frames are arriving.
  live,

  /// Connected, and the device is simply not drawing anything new. **Not a
  /// fault:** scrcpy encodes on change, so a still screen sends no frames at all.
  idle,

  /// Bytes are arriving and nothing is decoding out of them. The picture on
  /// screen is stale and the pipeline, not the device, is the reason.
  stalled,

  /// The socket closed or the server exited. Nothing more will arrive.
  ended,
}

/// What one watchdog tick can see, as ages rather than clocks, so the rule that
/// reads them is pure. [sinceInput] is the only evidence the user is waiting.
class StreamClocks {
  const StreamClocks({
    required this.sinceFrame,
    required this.sinceByte,
    required this.sinceDelivery,
    required this.sinceInput,
    required this.unansweredInputs,
    required this.framesSeen,
    this.watching = true,
  });

  /// Since a frame was decoded out of the socket.
  final Duration sinceFrame;

  /// Since any byte arrived, decodable or not.
  final Duration sinceByte;

  /// Since a frame was handed to the video player. **`null` when none ever has**
  /// — no viewer has connected yet, which is not evidence of anything.
  final Duration? sinceDelivery;

  /// Since the user last asked the device to do something. `null` when they
  /// have not.
  final Duration? sinceInput;

  /// Interactions since the last frame arrived. Interactions, not events: a
  /// drag is one, however many pointer moves it is made of.
  final int unansweredInputs;

  /// Whether any frame has ever decoded. Before that the start path is still
  /// reporting and the watchdog has nothing to add.
  final bool framesSeen;

  /// Whether the picture is on screen at all. A minimised window stops taking
  /// frames, which is indistinguishable from a player that has seized up.
  final bool watching;
}

/// One tick's conclusion.
class StreamVerdict {
  const StreamVerdict(this.state, this.detail, [this.since]);

  final DeviceStreamState state;
  final String detail;

  /// How long the thing this verdict is about has been true, so the UI can stop
  /// claiming certainty: four seconds of stillness is not four minutes of it.
  final Duration? since;

  @override
  String toString() => 'StreamVerdict($state, $detail)';
}

/// How long an interaction is given to reach the device and come back;
/// `adb shell input` alone costs a couple of hundred milliseconds.
const Duration kInputAnswerGrace = Duration(seconds: 3);

/// How many unanswered interactions it takes to condemn a stream. More than one:
/// tapping somewhere that does nothing is an ordinary thing to do.
const int kInputPatience = 3;

/// Everything that can condemn a live view, in one pure place; `null` when there
/// is nothing to say. Frames arriving is not enough — they may never be shown.
StreamVerdict? judgeStream(
  StreamClocks clocks, {
  required Duration stallTimeout,
  Duration inputGrace = kInputAnswerGrace,
  int inputPatience = kInputPatience,
}) {
  if (!clocks.framesSeen) return null;
  int seconds(Duration age) => (age.inMilliseconds / 1000).round();

  if (clocks.sinceFrame <= stallTimeout) {
    final delivery = clocks.sinceDelivery;
    if (clocks.watching && delivery != null && delivery > stallTimeout) {
      return StreamVerdict(
        DeviceStreamState.stalled,
        'The device is sending frames but the picture has not updated for '
        '${seconds(delivery)}s.',
        delivery,
      );
    }
    return const StreamVerdict(DeviceStreamState.live, 'Streaming.');
  }

  if (clocks.sinceByte < stallTimeout) {
    return StreamVerdict(
      DeviceStreamState.stalled,
      'The stream is still sending data but no frame has decoded for '
      '${seconds(clocks.sinceFrame)}s.',
      clocks.sinceFrame,
    );
  }

  final sinceInput = clocks.sinceInput;
  if (sinceInput != null &&
      sinceInput >= inputGrace &&
      clocks.unansweredInputs >= inputPatience) {
    return StreamVerdict(
      DeviceStreamState.stalled,
      'The device has not answered input for ${seconds(sinceInput)}s.',
      sinceInput,
    );
  }

  return StreamVerdict(
    DeviceStreamState.idle,
    'No screen changes for ${seconds(clocks.sinceFrame)}s.',
    clocks.sinceFrame,
  );
}

/// A health report for one live view. [state] separates the three things that
/// look identical on screen; only bytes-without-frames is ours to fix.
class DeviceStreamHealth {
  const DeviceStreamHealth({
    required this.state,
    required this.detail,
    this.since,
    this.bytesArriving = false,
    this.serverLog = const [],
  });

  /// How long this has been true, when the report is about a duration.

  final DeviceStreamState state;

  /// One line the user can act on.
  final String detail;

  /// See the constructor: the age the verdict was about, or `null`.
  final Duration? since;

  /// Whether the socket has produced any bytes recently, even unparsable ones.
  final bool bytesArriving;

  /// The last few lines scrcpy-server wrote to stderr. When a server dies it
  /// usually says why, and that message is otherwise thrown away.
  final List<String> serverLog;

  /// Whether the live view is working. An idle device counts: nothing is
  /// wrong with a stream whose device has nothing new to show.
  bool get isHealthy =>
      state == DeviceStreamState.live || state == DeviceStreamState.idle;

  /// Whether this is worth tearing the stream down for — never mere frame
  /// silence, which is what a device does when nobody is touching it.
  bool get needsRestart =>
      state == DeviceStreamState.stalled || state == DeviceStreamState.ended;

  @override
  String toString() => 'DeviceStreamHealth($state, $detail)';
}

/// A running live view of one device.
class DeviceStreamSession {
  DeviceStreamSession._({
    required this.serial,
    required this.url,
    required this.onStop,
    required this.openTransportStream,
    required this.videoSizeChanges,
    required this.health,
    required this.mark,
    required this.control,
    required this.videoSize,
    required this.openAccessUnits,
    required this.setQuiet,
  });

  final String serial;

  /// Opens a fresh MPEG-TS stream of this session's video for one more consumer.
  /// **A second consumer costs the device nothing**; only the muxer is per-stream.
  final MediaStreamFactory openTransportStream;

  /// Opens the same frames as [openTransportStream], unmuxed, for a sink that
  /// muxes its own container.
  final AccessUnitStreamFactory openAccessUnits;

  /// Newest frame seen and the timestamps needed to measure lag against it.
  final LiveFrameMark mark;

  /// What the video player opens. An MPEG-TS stream over loopback HTTP.
  final Uri url;

  /// Emits whenever the device's video geometry changes (rotation, resize).
  final Stream<DeviceScreenSize> videoSizeChanges;

  /// Emits every time the stream's health changes. Never emits [
  /// DeviceStreamState.live] twice in a row.
  final Stream<DeviceStreamHealth> health;

  /// scrcpy's control socket, or `null` when it could not be opened — in which
  /// case input falls back to `adb shell input` and nothing else changes.
  final ScrcpyControlConnection? control;

  /// The size of the encoded video, which is **not** the screen size: `max_size`
  /// scales it down, and a touch declaring the wrong size is dropped silently.
  DeviceScreenSize? videoSize;

  /// Tears down the socket, the scrcpy process, the tunnel and the HTTP shim.
  final Future<void> Function() onStop;

  /// Tells the stream the user has asked the device for something; the watchdog
  /// cannot judge silence without it.
  void noteInput() => mark.noteInput();

  /// Tells the stream whether its picture is on screen at all, so a window
  /// nobody can see is not accused of being behind.
  void setWatched(bool value) => mark.watching = value;

  /// Pauses taking bytes off the device's socket, and resumes. For the seconds a
  /// host file dialog is built on this isolate; resuming rebases the clocks.
  final void Function(bool quiet) setQuiet;

  /// Asks the device to restart video capture over the control socket — the
  /// cheapest recovery there is. False when there is no control socket to ask.
  bool requestVideoReset() {
    final connection = control;
    if (connection == null) return false;
    return connection.send(encodeResetVideo());
  }

  Future<void> stop() => onStop();
}

/// A socket that has proven it is actually carrying the video stream, together
/// with the first chunk read from it while proving that.
class _ServingConnection {
  _ServingConnection(this.socket, this.firstChunk, this.subscription);

  final Socket socket;
  final Uint8List firstChunk;

  /// A socket can only be listened to once, so the subscription opened while
  /// proving the stream is alive is handed over rather than recreated.
  final StreamSubscription<Uint8List> subscription;
}

/// Everything one successful tunnel attempt produced.
class _Tunnel {
  _Tunnel({
    required this.scid,
    required this.port,
    required this.server,
    required this.serverLog,
    required this.video,
    required this.control,
  });

  final String scid;
  final int port;
  final ProcessHandle server;

  /// The last few lines the server wrote to stderr, newest last.
  final List<String> serverLog;
  final _ServingConnection video;
  final ScrcpyControlConnection? control;
}

/// Deploys scrcpy-server to a device and republishes its H.264 output as MPEG-TS
/// on loopback HTTP: libmpv cannot open a raw H.264 elementary stream.
class DeviceStreamService {
  DeviceStreamService({
    required this.adb,
    required this.runner,
    required this.serverBytes,
    this.stallTimeout = const Duration(seconds: 6),
    this.watchdogInterval = const Duration(seconds: 1),
    this.livenessProbeInterval = const Duration(seconds: 20),
    this.inputAnswerGrace = kInputAnswerGrace,
    this.socketAttempts = 20,
    Directory? stagingDirectory,
    Logger? logger,
  }) : stagingDirectory = stagingDirectory ?? Directory.systemTemp,
       _logger = logger ?? Logger('device-stream');

  final AdbService adb;
  final CommandRunner runner;
  final ScrcpyServerBytes serverBytes;

  /// How long the picture may stand still before the stream says so. It decides
  /// what is *reported*, never what is torn down.
  final Duration stallTimeout;

  final Duration watchdogInterval;

  /// How long frame silence may run before the device is asked whether this
  /// session's server is alive — the one failure that raises no socket event.
  final Duration livenessProbeInterval;

  /// How long an interaction is given to be answered before the live view is
  /// called unresponsive. See [kInputAnswerGrace].
  final Duration inputAnswerGrace;

  /// How many times one tunnel attempt probes for a streaming socket, at 300 ms
  /// apiece. Injectable so a test does not spend six seconds per attempt.
  final int socketAttempts;

  /// Where the server jar is staged on the host before it is pushed; a per-test
  /// directory in tests, so a test and a live session cannot see each other's.
  final Directory stagingDirectory;

  final Logger _logger;

  /// Distinguishes concurrent starts inside one process; [pid] distinguishes
  /// processes. Together they make [scrcpyHostJarName] collision-free.
  static int _stageSequence = 0;

  /// Kills scrcpy servers and removes `adb forward` entries an earlier run left
  /// on [serial]. Killing the host-side `adb shell` does not kill `app_process`.
  Future<int> reapOrphans(String serial) async {
    var reaped = 0;
    // The **prefix**, because every session now deploys its own jar: matching
    // one exact path would leave every other session's orphan alive.
    final pids = parseOwnedScrcpyPids(
      await adb.processList(serial),
      jarPath: kScrcpyJarPathPrefix,
    );
    if (pids.isNotEmpty) {
      _logger.warning(
        'Reaping ${pids.length} orphaned scrcpy server(s) on $serial: $pids',
      );
      await adb.killPids(serial, pids);
      reaped += pids.length;
    }
    final ports = parseScrcpyForwards(await adb.listForwards(), serial: serial);
    for (final port in ports) {
      _logger.warning('Removing stale adb forward tcp:$port on $serial.');
      await adb.removeForward(serial, port);
      reaped += 1;
    }
    return reaped;
  }

  /// Writes the server jar to a path only this start uses, and clears out
  /// whatever earlier starts left behind.
  Future<File> _stageServerJar() async {
    await sweepStagedJars();
    final token =
        '${pid.toRadixString(16)}-${(_stageSequence++).toRadixString(16)}';
    final file = File(
      '${stagingDirectory.path}${Platform.pathSeparator}'
      '${scrcpyHostJarName(token)}',
    );
    await file.writeAsBytes(await serverBytes(), flush: true);
    return file;
  }

  Future<void> _discardStagedJar(File jar) async {
    try {
      if (jar.existsSync()) await jar.delete();
    } on FileSystemException catch (error) {
      // A jar that cannot be deleted is one more file for the next sweep, not
      // a reason to fail a stream that is already running.
      _logger.warning('Could not remove staged jar ${jar.path}: $error');
    }
  }

  /// Deletes staged jars older than [kStagedJarLifetime]: a start killed before
  /// its `finally` runs leaves 700 KB behind, which a fixed path never did.
  Future<int> sweepStagedJars() async {
    var swept = 0;
    final now = DateTime.now();
    try {
      await for (final entity in stagingDirectory.list(followLinks: false)) {
        if (entity is! File) continue;
        if (!entity.uri.pathSegments.last.startsWith(kScrcpyHostJarPrefix)) {
          continue;
        }
        try {
          if (now.difference((await entity.stat()).modified) <
              kStagedJarLifetime) {
            continue;
          }
          await entity.delete();
          swept += 1;
        } on FileSystemException {
          // Another process staging or deleting the same file at the same
          // moment. Its own sweep will get it.
        }
      }
    } on FileSystemException catch (error) {
      _logger.warning('Could not sweep staged scrcpy jars: $error');
    }
    if (swept > 0) _logger.info('Removed $swept stale staged scrcpy jar(s).');
    return swept;
  }

  /// Opens both sockets, *then* waits for bytes. `adb forward` accepts the host
  /// side before the device side exists, and `control=true` sends no video until
  /// the control socket connects — waiting for video first deadlocks.
  Future<({_ServingConnection video, ScrcpyControlConnection? control})?>
  _connectSockets(int port, {required bool withControl, int? attempts}) async {
    final limit = attempts ?? socketAttempts;
    for (var attempt = 0; attempt < limit; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      Socket candidate;
      try {
        candidate = await Socket.connect('127.0.0.1', port);
      } on SocketException {
        continue; // Tunnel not up yet.
      }
      candidate.setOption(SocketOption.tcpNoDelay, true);

      ScrcpyControlConnection? control;
      if (withControl) {
        try {
          control = ScrcpyControlConnection(
            await Socket.connect('127.0.0.1', port),
            logger: _logger,
          );
        } on SocketException {
          candidate.destroy();
          continue;
        }
      }

      final first = Completer<Uint8List?>();
      final subscription = candidate.listen(
        (data) {
          if (!first.isCompleted) first.complete(data);
        },
        onDone: () {
          if (!first.isCompleted) first.complete(null);
        },
        onError: (Object _) {
          if (!first.isCompleted) first.complete(null);
        },
      );
      final chunk = await first.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () => null,
      );
      subscription.pause();

      if (chunk != null && chunk.isNotEmpty) {
        return (
          video: _ServingConnection(candidate, chunk, subscription),
          control: control,
        );
      }
      await subscription.cancel();
      candidate.destroy();
      await control?.close();
    }
    return null;
  }

  /// Capture geometry and rate for one class of device. Measured: asking the
  /// encoder for more fps than it sustains queues frames on the device and adds
  /// lag, so the right rate is just under what it can do.
  static const ({int maxSize, int maxFps}) _hardwareEncoder = (
    maxSize: 1024,
    maxFps: 60,
  );
  static const ({int maxSize, int maxFps}) _softwareEncoder = (
    maxSize: 1024,
    maxFps: 10,
  );

  /// Emulators run a software encoder; adb names them `emulator-<port>`.
  static bool isEmulatorSerial(String serial) => serial.startsWith('emulator-');

  Future<DeviceStreamSession> start(
    String serial, {
    int? maxSize,
    int? maxFps,
    bool useControlSocket = true,
  }) async {
    final profile = isEmulatorSerial(serial)
        ? _softwareEncoder
        : _hardwareEncoder;
    final captureSize = maxSize ?? profile.maxSize;
    final captureFps = maxFps ?? profile.maxFps;

    await reapOrphans(serial);

    final hostJar = await _stageServerJar();

    // Control first, then without it: `control=true` changes the *video*
    // handshake, and losing the picture for an input upgrade is a bad trade.
    _Tunnel? tunnel;
    var attemptedWithoutControl = false;
    try {
      for (final wantControl
          in useControlSocket ? const [true, false] : const [false]) {
        tunnel = await _openTunnel(
          serial: serial,
          hostJarPath: hostJar.path,
          captureSize: captureSize,
          captureFps: captureFps,
          withControl: wantControl,
        );
        if (tunnel != null) break;
        attemptedWithoutControl = !wantControl;
      }
    } finally {
      // Nothing reads it after the last push, so it goes now rather than
      // waiting for a later start's sweep to notice it.
      await _discardStagedJar(hostJar);
    }
    if (tunnel == null) {
      throw StateError(
        'scrcpy-server did not start streaming'
        '${attemptedWithoutControl ? ' (tried with and without the control socket)' : ''}.',
      );
    }
    final scid = tunnel.scid;
    final localPort = tunnel.port;
    final server = tunnel.server;
    final serverLog = tunnel.serverLog;
    final connection = tunnel.video;
    final control = tunnel.control;
    if (control == null) {
      _logger.warning(
        'Device $serial: no control socket; input falls back to adb input.',
      );
    }
    final socket = connection.socket;

    final mark = LiveFrameMark();
    DeviceScreenSize? videoSize;
    final sizes = StreamController<DeviceScreenSize>.broadcast();
    final frames = StreamController<ScrcpyFrame>.broadcast();
    final parser = ScrcpyStreamParser();
    Uint8List? codecConfig;
    // The most recent keyframe, so a viewer connecting mid-stream can start
    // immediately instead of waiting for the next one.
    ScrcpyFrame? lastKeyFrame;

    // Two clocks: `lastByteUs` says the socket is alive, `mark.arrivalUs` says
    // frames are decoding out of it. Which of them stopped is the diagnosis.
    var lastByteUs = DateTime.now().microsecondsSinceEpoch;
    final healthController = StreamController<DeviceStreamHealth>.broadcast();
    var lastState = DeviceStreamState.live;
    var lastDetail = '';

    // Set by [stop] before it kills anything. Dart's `Process.kill` reports exit
    // code -1 on Windows, which used to reach the user as a failure line.
    var stopped = false;

    void report(DeviceStreamState state, String detail, [Duration? since]) {
      // The state machine only moves forwards: a stream that has ended must not
      // read as healthy again while the frame clock runs out.
      if (lastState == DeviceStreamState.ended &&
          state != DeviceStreamState.ended) {
        return;
      }
      if (state == lastState && detail == lastDetail) return;
      lastState = state;
      lastDetail = detail;
      if (healthController.isClosed) return;
      healthController.add(
        DeviceStreamHealth(
          state: state,
          detail: detail,
          since: since,
          bytesArriving:
              DateTime.now().microsecondsSinceEpoch - lastByteUs <
              stallTimeout.inMicroseconds,
          serverLog: List.unmodifiable(serverLog),
        ),
      );
    }

    void handleChunk(List<int> chunk) {
      lastByteUs = DateTime.now().microsecondsSinceEpoch;
      for (final packet in parser.add(chunk)) {
        switch (packet) {
          case ScrcpyCodec():
            break;
          case ScrcpySessionMeta(:final width, :final height):
            // Also the coordinate space every touch message must declare.
            final size = DeviceScreenSize(width: width, height: height);
            if (size != videoSize) {
              videoSize = size;
              sizes.add(size);
            }
          case ScrcpyFrame frame:
            if (frame.isConfig) {
              codecConfig = frame.data;
            } else {
              if (frame.isKeyFrame) lastKeyFrame = frame;
              mark
                ..frames += 1
                ..ptsUs = frame.ptsUs
                ..arrivalUs = DateTime.now().microsecondsSinceEpoch
                // Whatever the user asked for, the device has answered.
                ..noteAnswered();
              frames.add(frame);
            }
        }
      }
    }

    handleChunk(connection.firstChunk);
    final socketSubscription = connection.subscription
      ..onData((chunk) {
        handleChunk(chunk);
        report(DeviceStreamState.live, 'Streaming.');
      })
      ..onDone(() {
        _logger.info('Device $serial stream ended.');
        report(DeviceStreamState.ended, 'The scrcpy stream closed.');
        if (!frames.isClosed) frames.close();
      })
      ..onError((Object error) {
        _logger.warning('Device $serial stream error: $error');
        report(DeviceStreamState.ended, 'The scrcpy stream failed: $error');
        if (!frames.isClosed) frames.close();
      })
      ..resume();

    // The server exiting is the failure that used to be invisible: the socket
    // may stay in a state where nothing arrives and nothing complains.
    unawaited(
      server.exitCode
          .then((code) {
            if (stopped) return;
            _logger.warning('Device $serial scrcpy-server exited with $code.');
            report(
              DeviceStreamState.ended,
              'scrcpy-server exited (code $code).'
              '${serverLog.isEmpty ? '' : ' ${serverLog.last}'}',
            );
          })
          .catchError((Object _) {}),
    );

    // Silence this app asked for. See [DeviceStreamSession.setQuiet].
    var quiet = false;
    void setQuiet(bool value) {
      if (stopped || quiet == value) return;
      quiet = value;
      if (value) {
        socketSubscription.pause();
        return;
      }
      // No clock may still point into the gap. Zeros are left alone: zero means
      // "has never happened", which the quiet window did not change.
      final now = DateTime.now().microsecondsSinceEpoch;
      lastByteUs = now;
      if (mark.frames > 0) mark.arrivalUs = now;
      if (mark.writtenUs != 0) mark.writtenUs = now;
      if (mark.lastInputUs != 0) mark.lastInputUs = now;
      socketSubscription.resume();
    }

    // The watchdog reports what the picture is doing; it never decides the stream
    // is broken. What it may conclude lives in [judgeStream], which is pure.
    var probeInFlight = false;
    var lastProbeUs = DateTime.now().microsecondsSinceEpoch;
    final watchdog = Timer.periodic(watchdogInterval, (_) {
      // Nothing has been let through since the last tick and nothing was meant
      // to be. Judging the gap would condemn the stream for obeying.
      if (quiet) return;
      final now = DateTime.now().microsecondsSinceEpoch;
      Duration age(int sinceUs) => Duration(microseconds: now - sinceUs);
      final verdict = judgeStream(
        StreamClocks(
          sinceFrame: age(mark.arrivalUs),
          sinceByte: age(lastByteUs),
          // Zero means it has never happened, which is not evidence: no viewer
          // has connected yet.
          sinceDelivery: mark.writtenUs == 0 ? null : age(mark.writtenUs),
          sinceInput: mark.lastInputUs == 0 ? null : age(mark.lastInputUs),
          unansweredInputs: mark.unansweredInputs,
          framesSeen: mark.frames > 0,
          watching: mark.watching,
        ),
        stallTimeout: stallTimeout,
        inputGrace: inputAnswerGrace,
      );
      if (verdict == null) return;
      report(verdict.state, verdict.detail, verdict.since);

      // Only idleness is worth going and looking at: every other verdict has
      // already said what is wrong.
      if (verdict.state != DeviceStreamState.idle) return;
      final sinceFrame = now - mark.arrivalUs;
      if (probeInFlight ||
          sinceFrame < livenessProbeInterval.inMicroseconds ||
          now - lastProbeUs < livenessProbeInterval.inMicroseconds) {
        return;
      }
      probeInFlight = true;
      lastProbeUs = now;
      unawaited(
        _serverStillRunning(serial, scid)
            .then((alive) {
              probeInFlight = false;
              // Only a definite "gone" counts. See [_serverStillRunning].
              if (stopped || alive != false) return;
              _logger.warning(
                'Device $serial: scrcpy-server $scid is no longer running.',
              );
              report(
                DeviceStreamState.ended,
                'scrcpy-server is no longer running on the device.'
                '${serverLog.isEmpty ? '' : ' ${serverLog.last}'}',
              );
            })
            .catchError((Object _) {
              probeInFlight = false;
            }),
      );
    });

    // The muxing is scrcpy-shaped — SPS/PPS ahead of every keyframe, a cached
    // keyframe replayed — while [LoopbackMediaServer] knows nothing about H.264.
    Uint8List accessUnitFor(ScrcpyFrame frame, Uint8List? config) =>
        (frame.isKeyFrame && config != null)
        ? Uint8List.fromList([...config, ...frame.data])
        : frame.data;

    Stream<List<int>> muxedForOneViewer() async* {
      // A fresh muxer per viewer: continuity counters and the timestamp base
      // belong to one output stream.
      final muxer = TsMuxer();
      yield muxer.tables();

      // Start from the cached keyframe when there is one, so a viewer does not
      // wait for the next one.
      var started = false;
      final cached = lastKeyFrame;
      if (cached != null) {
        mark.basePtsUs ??= cached.ptsUs;
        yield muxer.frame(
          accessUnitFor(cached, codecConfig),
          cached.ptsUs,
          keyframe: true,
        );
        started = true;
      }

      await for (final frame in frames.stream) {
        // A decoder handed a mid-GOP frame first has nothing to predict from.
        if (!started) {
          if (!frame.isKeyFrame) continue;
          started = true;
        }
        mark.basePtsUs ??= frame.ptsUs;
        yield muxer.frame(
          accessUnitFor(frame, codecConfig),
          frame.ptsUs,
          keyframe: frame.isKeyFrame,
        );
      }
    }

    DeviceAccessUnit unitFor(ScrcpyFrame frame) {
      final size = videoSize;
      return DeviceAccessUnit(
        bytes: accessUnitFor(frame, codecConfig),
        ptsUs: frame.ptsUs,
        keyframe: frame.isKeyFrame,
        width: size?.width ?? 0,
        height: size?.height ?? 0,
        // Annex-B SPS/PPS, which is what an MP4 sample entry is built from.
        sequenceHeader: codecConfig ?? Uint8List(0),
      );
    }

    Stream<DeviceAccessUnit> accessUnitsForOneConsumer() async* {
      var started = false;
      final cached = lastKeyFrame;
      if (cached != null) {
        yield unitFor(cached);
        started = true;
      }
      await for (final frame in frames.stream) {
        // A decoder handed a mid-GOP frame first has nothing to predict from.
        if (!started) {
          if (!frame.isKeyFrame) continue;
          started = true;
        }
        yield unitFor(frame);
      }
    }

    final http = await LoopbackMediaServer.serve(
      openStream: muxedForOneViewer,
      onChunkWritten: () =>
          mark.writtenUs = DateTime.now().microsecondsSinceEpoch,
    );

    Future<void> stop() async {
      if (stopped) return;
      stopped = true;
      watchdog.cancel();
      await control?.close();
      await socketSubscription.cancel();
      socket.destroy();
      if (!frames.isClosed) await frames.close();
      if (!sizes.isClosed) await sizes.close();
      if (!healthController.isClosed) await healthController.close();
      await http.close();
      // Killing the host-side `adb shell` leaves the `app_process` it started
      // running on the device, and the forward outlives both.
      await server.kill();
      await _killDeviceServers(serial, scid);
      await adb.removeForward(serial, localPort);
      _logger.info('Device $serial stream stopped.');
    }

    final session = DeviceStreamSession._(
      serial: serial,
      url: http.url,
      onStop: stop,
      openTransportStream: muxedForOneViewer,
      openAccessUnits: accessUnitsForOneConsumer,
      videoSizeChanges: sizes.stream,
      health: healthController.stream,
      mark: mark,
      control: control,
      videoSize: videoSize,
      setQuiet: setQuiet,
    );
    // Rotation and resize change the coordinate space touch messages must
    // declare; a stale value makes every later touch vanish silently.
    sizes.stream.listen((size) => session.videoSize = size);
    return session;
  }

  /// One attempt at forward → server → sockets, torn down completely if any
  /// step fails so a retry does not leak a server or a forward.
  Future<_Tunnel?> _openTunnel({
    required String serial,
    required String hostJarPath,
    required int captureSize,
    required int captureFps,
    required bool withControl,
  }) async {
    // adb picks the port, so we never collide with a reserved range. The scid
    // must fit a signed 32-bit int or `Options.parse` aborts the server.
    final scid = Random().nextInt(0x7FFFFFFF).toRadixString(16).padLeft(8, '0');

    // The jar goes on the device **here**, once per attempt, because the server
    // this attempt starts will delete it. See [scrcpyJarPathFor].
    final devicePath = scrcpyJarPathFor(scid);
    final push = await runner.run(
      CommandRequest(
        executable: adb.sdk.adb.path,
        arguments: ['-s', serial, 'push', hostJarPath, devicePath],
      ),
    );
    if (!push.ok) {
      throw StateError('Could not deploy scrcpy-server: ${push.stderr.trim()}');
    }

    final forward = await runner.run(
      CommandRequest(
        executable: adb.sdk.adb.path,
        arguments: [
          '-s',
          serial,
          'forward',
          'tcp:0',
          'localabstract:scrcpy_$scid',
        ],
      ),
    );
    final port = parseForwardedPort(forward.stdout);
    if (!forward.ok || port == null) {
      throw StateError(
        'Could not open an adb tunnel: ${forward.stderr.trim()}',
      );
    }

    // raw_stream stays OFF: we want scrcpy's per-frame timestamps and keyframe
    // flags for the MPEG-TS mux.
    final server = await runner.start(
      CommandRequest(
        executable: adb.sdk.adb.path,
        arguments: [
          '-s',
          serial,
          'shell',
          'CLASSPATH=$devicePath',
          'app_process',
          '/',
          'com.genymobile.scrcpy.Server',
          kScrcpyVersion,
          'scid=$scid',
          'log_level=warn',
          'tunnel_forward=true',
          'audio=false',
          // Enabling control also changes the video handshake — see
          // [_connectSockets].
          'control=${withControl ? 'true' : 'false'}',
          'cleanup=true',
          'send_device_meta=false',
          'send_dummy_byte=false',
          'max_size=$captureSize',
          'video_codec=h264',
          'max_fps=$captureFps',
          // A keyframe every second, so a viewer connecting between them has
          // something it can start decoding from.
          'video_codec_options=i-frame-interval=1',
        ],
      ),
    );
    // When the server dies it normally explains itself on stderr; the pane shows
    // it, because "the live view stopped" is not a report anyone can act on.
    final serverLog = <String>[];
    unawaited(
      server.stderrLines.forEach((line) {
        _logger.warning('scrcpy: $line');
        serverLog.add(line);
        if (serverLog.length > 20) serverLog.removeAt(0);
      }),
    );

    final sockets = await _connectSockets(port, withControl: withControl);
    if (sockets != null) {
      return _Tunnel(
        scid: scid,
        port: port,
        server: server,
        serverLog: serverLog,
        video: sockets.video,
        control: sockets.control,
      );
    }
    _logger.warning(
      'Device $serial: scrcpy did not stream with control='
      '$withControl.${serverLog.isEmpty ? '' : ' ${serverLog.join(' / ')}'}',
    );
    await server.kill();
    await _killDeviceServers(serial, scid);
    await adb.removeForward(serial, port);
    // A server that never started never unlinked itself, so this attempt's jar
    // is still there — 700 KB of /data/local/tmp per failed attempt otherwise.
    await _removeDeviceJar(serial, devicePath);
    return null;
  }

  /// Whether this session's server is still in the device's process table. Three
  /// answers: `null` is "adb could not tell us", which is not "gone".
  Future<bool?> _serverStillRunning(String serial, String scid) async {
    final table = await adb.processList(serial);
    if (table.trim().isEmpty) return null;
    return parseOwnedScrcpyPids(
      table,
      jarPath: scrcpyJarPathFor(scid),
    ).isNotEmpty;
  }

  /// Best-effort removal of one attempt's jar. Failure is not worth reporting:
  /// the usual reason is that scrcpy-server already deleted it itself.
  Future<void> _removeDeviceJar(String serial, String devicePath) async {
    try {
      await runner.run(
        CommandRequest(
          executable: adb.sdk.adb.path,
          arguments: ['-s', serial, 'shell', 'rm', '-f', devicePath],
        ),
      );
    } catch (error) {
      _logger.info('Could not remove $devicePath on $serial: $error');
    }
  }

  /// Kills the device-side server for one session, matched on `scid=` so another
  /// live view is untouched. The `[d]` stops the pattern matching its own `pkill`.
  Future<void> _killDeviceServers(String serial, String scid) async {
    try {
      await runner.run(
        CommandRequest(
          executable: adb.sdk.adb.path,
          arguments: ['-s', serial, 'shell', 'pkill', '-f', 'sci[d]=$scid'],
        ),
      );
    } catch (error) {
      _logger.warning('Could not kill scrcpy server $scid on $serial: $error');
    }
  }
}
