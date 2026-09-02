import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../../core/logging/app_logger.dart';
import '../../../core/process/command_runner.dart';
import '../../../core/process/process_handle.dart';
import '../domain/device_input.dart';
import 'adb_output_parsing.dart';
import 'adb_service.dart';
import 'scrcpy_control.dart';
import 'scrcpy_protocol.dart';
import 'loopback_media_server.dart';
import 'ts_muxer.dart';

/// scrcpy release this app deploys. The jar and the version string handed to
/// `app_process` must match exactly or the server refuses to start.
const String kScrcpyVersion = '4.1';

/// Where the server jar is bundled in the Flutter asset bundle.
const String kScrcpyServerAsset = 'assets/scrcpy/scrcpy-server';

/// Everything this app pushes to a device starts with this, and nothing else
/// does. `reapOrphans` matches on it, so it must stay distinct from the
/// `/data/local/tmp/scrcpy-server.jar` a developer's own scrcpy uses.
const String kScrcpyJarPathPrefix = '/data/local/tmp/karmashala-scrcpy-server';

/// The jar path for one session.
///
/// One path **per session**, not one for the app, and that is a fix rather than
/// tidiness. scrcpy-server 4.1 deletes its own jar as it starts (`unlinkSelf`),
/// so a shared path is gone the moment any server has run: the very next
/// `app_process` finds no class and aborts with
/// `ClassNotFoundException: com.genymobile.scrcpy.Server`. That is not a corner
/// case — [DeviceStreamService.start] makes two attempts in a row
/// (`control=true`, then `control=false`), and with one path the second could
/// never work. Reproduced on F6IZLV6LMFT4U4ZT: SIGABRT, adb printing
/// "Aborted", exit 134.
String scrcpyJarPathFor(String scid) => '$kScrcpyJarPathPrefix-$scid.jar';

/// Supplies the scrcpy server jar bytes (the Flutter asset in the app, a
/// fixture in tests).
typedef ScrcpyServerBytes = Future<Uint8List> Function();

/// Parses the port adb allocated for `adb forward tcp:0 …`.
///
/// Asking adb for port 0 avoids both a bind race and Windows' reserved port
/// ranges — scrcpy's default 27183 was already unavailable on this machine.
int? parseForwardedPort(String output) {
  for (final line in output.split(RegExp(r'[\r\n]+'))) {
    final port = int.tryParse(line.trim());
    if (port != null && port > 0) return port;
  }
  return null;
}

/// Timestamps of the newest frame in flight, so latency can be measured
/// without instrumenting the socket from outside.
///
/// Everything here is microseconds. [ptsUs] is scrcpy's timestamp, which is the
/// **device's** monotonic clock at capture; [arrivalUs] is the host wall clock
/// when that frame finished arriving. [basePtsUs] is the timestamp the muxer
/// rebased the stream onto — what the player calls position zero — so a
/// player's reported position can be turned back into a device capture time.
class LiveFrameMark {
  int frames = 0;
  int ptsUs = 0;
  int arrivalUs = 0;
  int? basePtsUs;

  /// Host clock when the newest frame was handed to the HTTP response, i.e.
  /// when it stopped being ours and became the player's problem.
  int writtenUs = 0;
}

/// What the live view is doing, as far as the app can tell from outside the
/// video player.
enum DeviceStreamState {
  /// Connected; frames are arriving.
  live,

  /// Connected, and the device is simply not drawing anything new.
  ///
  /// **Not a fault, and the whole point of this value.** scrcpy encodes on
  /// change: a phone left on a home screen sends no frames at all — it asks the
  /// encoder for `repeat-previous-frame-after`, which the platform honours for
  /// a short burst and then stops. Treating that silence as a stall is what
  /// restarted the owner's live view every eleven seconds for nine minutes on
  /// F6IZLV6LMFT4U4ZT, with no socket closing and no server exiting in the log.
  idle,

  /// Bytes are arriving and nothing is decoding out of them. The picture on
  /// screen is stale and the pipeline, not the device, is the reason.
  stalled,

  /// The socket closed or the server exited. Nothing more will arrive.
  ended,
}

/// A health report for one live view.
///
/// [bytesArriving] is the field worth reading first when something is wrong:
/// "no bytes at all" (the server died, or its tunnel is stale) and "bytes but
/// no frames" (the stream is alive and we are failing to decode or present it)
/// look identical on screen — a frozen picture — and have completely different
/// causes. Loop 36 found the first, on a physical device whose scrcpy server had
/// exited while its `adb forward` entry stayed registered.
class DeviceStreamHealth {
  const DeviceStreamHealth({
    required this.state,
    required this.detail,
    this.bytesArriving = false,
    this.serverLog = const [],
  });

  final DeviceStreamState state;

  /// One line the user can act on.
  final String detail;

  /// Whether the socket has produced any bytes recently, even unparsable ones.
  final bool bytesArriving;

  /// The last few lines scrcpy-server wrote to stderr. When a server dies it
  /// usually says why, and that message is otherwise thrown away.
  final List<String> serverLog;

  /// Whether the live view is working. An idle device counts: nothing is
  /// wrong with a stream whose device has nothing new to show.
  bool get isHealthy =>
      state == DeviceStreamState.live || state == DeviceStreamState.idle;

  /// Whether this is worth tearing the stream down for.
  ///
  /// Only the two states that mean the pipeline is broken — never mere frame
  /// silence, which is what the device does when nobody is touching it.
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
    required this.videoSizeChanges,
    required this.health,
    required this.mark,
    required this.control,
    required this.videoSize,
  });

  final String serial;

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

  /// The size of the encoded video, which is **not** the device's screen size:
  /// `max_size` scales it down. Touch messages must declare this exact size or
  /// scrcpy's `PositionMapper` drops them without a word. It changes when the
  /// device rotates, so it is mutable and kept current by the stream.
  DeviceScreenSize? videoSize;

  /// Tears down the socket, the scrcpy process, the tunnel and the HTTP shim.
  final Future<void> Function() onStop;

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

/// Deploys scrcpy-server to a device and republishes its H.264 output as an
/// MPEG-TS stream on loopback HTTP.
///
/// The indirection through HTTP exists because libmpv cannot open a raw H.264
/// elementary stream, and because a local URL is the one input every video
/// player accepts.
class DeviceStreamService {
  DeviceStreamService({
    required this.adb,
    required this.runner,
    required this.serverBytes,
    this.stallTimeout = const Duration(seconds: 6),
    this.watchdogInterval = const Duration(seconds: 1),
    this.livenessProbeInterval = const Duration(seconds: 20),
    this.socketAttempts = 20,
    AppLogger? logger,
  }) : _logger = logger ?? AppLogger.named('device-stream');

  final AdbService adb;
  final CommandRunner runner;
  final ScrcpyServerBytes serverBytes;

  /// How long the picture may stand still before the stream says so.
  ///
  /// It decides what is *reported*, never what is torn down. The comment that
  /// used to be here claimed a static screen "still sends frames, but slowly";
  /// it does not send any, which is why this timeout used to end a working
  /// stream every few seconds.
  final Duration stallTimeout;

  final Duration watchdogInterval;

  /// How long frame silence may run before the device is asked whether this
  /// session's server is still alive.
  ///
  /// Silence is normal, so it is not evidence — but it is the moment worth
  /// spending one `ps` on, because the one failure that produces silence *and*
  /// no socket event is a server that died leaving its `adb forward` and the
  /// host-side socket up (Loop 36, on a physical device).
  final Duration livenessProbeInterval;

  /// How many times one tunnel attempt probes for a streaming socket, at 300 ms
  /// apiece. Injectable so a test does not spend six seconds per attempt
  /// waiting for a port nothing will ever answer on.
  final int socketAttempts;

  final AppLogger _logger;

  /// Kills scrcpy servers and removes `adb forward` entries left behind by an
  /// earlier run on [serial].
  ///
  /// Both leaks are real and were observed together: on one device the server
  /// had exited while its forward stayed registered, and on another four
  /// servers were alive at once because killing the host-side `adb shell` does
  /// **not** kill the `app_process` it started on the device. Neither is
  /// self-correcting, so every start begins by clearing them.
  ///
  /// A tidy [DeviceStreamSession.stop] is not enough on its own, either: the
  /// pane's `dispose` cannot await it, so closing the app leaves whatever the
  /// teardown had not finished. Reaping on the way *in* is the only cleanup
  /// that always gets to run.
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

  /// Connects the tunnel's sockets, retrying until the server is really
  /// streaming.
  ///
  /// Two hazards, and the order below is the only one that clears both.
  ///
  /// **`adb forward` accepts the host-side TCP connection before the
  /// device-side socket exists**, then closes it. A successful `connect()`
  /// therefore proves nothing; only bytes do.
  ///
  /// **With `control=true` the server sends no video until the control socket
  /// is also connected.** `DesktopConnection.open` accepts video, then audio,
  /// then control, and only *then* returns and lets the encoder start. Waiting
  /// for video bytes before opening the control socket deadlocks: the client
  /// waits for a byte the server will not send until the client connects again.
  /// That is not a hypothetical — it is what this loop's first run on a
  /// physical device did, retrying for ten seconds and reporting the server had
  /// never started.
  ///
  /// So: open both sockets, *then* wait for bytes. Video arriving proves the
  /// whole handshake, control socket included.
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

  /// Capture geometry and rate for one class of device.
  ///
  /// The rate is the whole difference between a live view and a laggy one.
  /// scrcpy asks the **encoder** to accept up to `max_fps`; when the encoder
  /// cannot sustain that rate the surplus frames queue up inside the device and
  /// every frame reaches us that much later. Asking for less than the encoder
  /// can do is not free either — the player holds about three frames, so each
  /// frame dropped from the rate costs three frame intervals of lag. The right
  /// setting is therefore *just under* what the device's encoder sustains.
  ///
  /// Measured on `emulator-5554` (1080x2400, software encoder) under continuous
  /// scrolling — device capture to host arrival, and the rate actually
  /// achieved:
  ///
  /// | max_size | max_fps | sustained | arrival p50 | arrival p90 |
  /// | --- | --- | --- | --- | --- |
  /// | 1024 | 60 | 13.2 | 1256 ms | 1739 ms |
  /// | 1024 | 15 | — | 895 ms | 1362 ms |
  /// | 1024 | 10 | 10.0 | 70 ms | 219 ms |
  /// | 640 | 60 | 20.0 | 706 ms | 1601 ms |
  /// | 640 | 30 | 22.7 | 284 ms | 542 ms |
  /// | 640 | 22 | 19.1 | 116 ms | 265 ms |
  /// | **640** | **20** | **18.5** | **71 ms** | **176 ms** |
  ///
  /// A physical device encodes in hardware and keeps up at 60, so it queues
  /// nothing and can have the full resolution.
  static const ({int maxSize, int maxFps}) _hardwareEncoder = (
    maxSize: 1024,
    maxFps: 60,
  );
  static const ({int maxSize, int maxFps}) _softwareEncoder = (
    maxSize: 640,
    maxFps: 20,
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

    // 0. Clear anything a previous run left running or registered.
    await reapOrphans(serial);

    // 1. Stage the jar on the host once. Putting it on the *device* is
    //    [_openTunnel]'s job, per attempt — see [scrcpyJarPathFor].
    final jar = await serverBytes();
    final hostJar = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'karmashala-scrcpy-server-$kScrcpyVersion.jar',
    );
    await hostJar.writeAsBytes(jar, flush: true);

    // 2–4. Tunnel, server, sockets. Attempted with the control socket first and
    // then without it, because enabling control changes the *video* handshake:
    // a server started with `control=true` streams nothing at all until a
    // control socket connects. If that cannot be established — an older server,
    // a device that refuses the second connection — the whole live view would
    // be lost for the sake of an input upgrade. Falling back to `control=false`
    // keeps exactly the Loop 27 behaviour, with `adb shell input` for gestures.
    _Tunnel? tunnel;
    var attemptedWithoutControl = false;
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

    // 5. Parse, mux, fan out.
    final mark = LiveFrameMark();
    DeviceScreenSize? videoSize;
    final sizes = StreamController<DeviceScreenSize>.broadcast();
    final frames = StreamController<ScrcpyFrame>.broadcast();
    final parser = ScrcpyStreamParser();
    Uint8List? codecConfig;
    // The most recent keyframe, so a viewer connecting mid-stream can start
    // immediately instead of waiting for the next one.
    ScrcpyFrame? lastKeyFrame;

    // Two clocks, deliberately. `lastByteUs` says the socket is alive;
    // `mark.arrivalUs` says frames are decoding out of it. When the picture
    // freezes, which of the two has stopped is the whole diagnosis.
    var lastByteUs = DateTime.now().microsecondsSinceEpoch;
    final healthController = StreamController<DeviceStreamHealth>.broadcast();
    var lastState = DeviceStreamState.live;
    var lastDetail = '';

    // Set by [stop] before it kills anything, and read by the exit watcher
    // below. Dart's `Process.kill` reports exit code -1 on Windows, so our own
    // teardown used to log and *show the user*
    // "scrcpy-server exited (code -1)" on every stop, restart and device
    // switch — the exact line that read as the failure in the owner's log.
    var stopped = false;

    void report(DeviceStreamState state, String detail) {
      // The state machine only ever moves forwards. A stream that has ended
      // cannot go back to being live, and the watchdog would otherwise call it
      // healthy again for the second between the socket closing and the frame
      // clock running out.
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
                ..arrivalUs = DateTime.now().microsecondsSinceEpoch;
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

    // The watchdog. It reports what the picture is doing; it does not decide
    // that the stream is broken, because frame silence is what a device with a
    // static screen looks like and tearing the stream down for it is the
    // restart loop this state machine now exists to end.
    //
    // The two clocks split the cases. Bytes arriving with no frame out of them
    // is ours to fix, so it stays a fault. Neither bytes nor frames is either
    // an idle device or a dead one, and the only honest way to tell them apart
    // is to go and look — [_serverStillRunning], once the silence has run long
    // enough to be worth an adb round trip.
    var probeInFlight = false;
    var lastProbeUs = DateTime.now().microsecondsSinceEpoch;
    final watchdog = Timer.periodic(watchdogInterval, (_) {
      final now = DateTime.now().microsecondsSinceEpoch;
      final sinceFrame = now - mark.arrivalUs;
      if (mark.frames == 0 || sinceFrame <= stallTimeout.inMicroseconds) {
        if (mark.frames > 0) report(DeviceStreamState.live, 'Streaming.');
        return;
      }
      final seconds = (sinceFrame / 1000000).round();
      if (now - lastByteUs < stallTimeout.inMicroseconds) {
        report(
          DeviceStreamState.stalled,
          'The stream is still sending data but no frame has decoded for '
          '${seconds}s.',
        );
        return;
      }
      report(DeviceStreamState.idle, 'No screen changes for ${seconds}s.');

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

    // 6. Serve MPEG-TS over loopback.
    //
    // The muxing lives here because it is scrcpy-shaped — SPS/PPS republished
    // ahead of every keyframe, a cached keyframe replayed so a viewer does not
    // wait for the next one — while the door itself is [LoopbackMediaServer],
    // which knows nothing about H.264 and is what a second live-view backend
    // uses too.
    Uint8List accessUnitFor(ScrcpyFrame frame, Uint8List? config) =>
        (frame.isKeyFrame && config != null)
        ? Uint8List.fromList([...config, ...frame.data])
        : frame.data;

    Stream<List<int>> muxedForOneViewer() async* {
      // A fresh muxer per viewer: continuity counters and the timestamp base
      // belong to one output stream, and replaying packets to a second viewer
      // would duplicate them.
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
      // Three separate things have to die, and the first does not imply the
      // others: killing the host-side `adb shell` leaves the `app_process` it
      // started running on the device, and the forward outlives both.
      await server.kill();
      await _killDeviceServers(serial, scid);
      await adb.removeForward(serial, localPort);
      _logger.info('Device $serial stream stopped.');
    }

    final session = DeviceStreamSession._(
      serial: serial,
      url: http.url,
      onStop: stop,
      videoSizeChanges: sizes.stream,
      health: healthController.stream,
      mark: mark,
      control: control,
      videoSize: videoSize,
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
    // adb picks the port, so we never collide with a reserved range — scrcpy's
    // default 27183 was already unavailable on this machine.
    //
    // The scid must fit a signed 32-bit int: `Options.parse` runs it through
    // `Integer.parseInt`, and anything larger aborts the server with a
    // `NumberFormatException` before it prints anything else.
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
          // Loop 36: the control socket. Note this also changes the video
          // handshake — see [_connectSockets].
          'control=${withControl ? 'true' : 'false'}',
          'cleanup=true',
          'send_device_meta=false',
          'send_dummy_byte=false',
          'max_size=$captureSize',
          'video_codec=h264',
          'max_fps=$captureFps',
          // A keyframe every second. Without this the encoder may go a long
          // time between keyframes, and a viewer that connects in between has
          // nothing it can start decoding from.
          'video_codec_options=i-frame-interval=1',
        ],
      ),
    );
    // Keep what the server says. When it dies it normally explains itself on
    // stderr, and that explanation used to go only to a log nobody reads — the
    // pane now shows it, because "the live view stopped" on its own is not a
    // report anyone can act on.
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

  /// Whether this session's server is still in the device's process table.
  ///
  /// Three answers, not two. `null` is "adb could not tell us", and it is the
  /// reason this is not a bool: a probe that read an empty process table as
  /// "the server is gone" would restart the live view every time adb hiccupped
  /// — the same fault as the stall watchdog, in a new place.
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

  /// Kills the device-side server for one session.
  ///
  /// Matched on `scid=`, which is unique per session, so a second live view on
  /// the same device — or a scrcpy the developer is running themselves — is
  /// untouched. The `[d]` is not a typo: it stops the pattern matching the
  /// `sh -c` that is running `pkill` itself.
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
