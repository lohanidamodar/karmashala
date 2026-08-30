import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../../core/logging/app_logger.dart';
import '../../../core/process/command_runner.dart';
import '../domain/device_input.dart';
import 'adb_output_parsing.dart';
import 'adb_service.dart';
import 'scrcpy_control.dart';
import 'scrcpy_protocol.dart';
import 'ts_muxer.dart';

/// scrcpy release this app deploys. The jar and the version string handed to
/// `app_process` must match exactly or the server refuses to start.
const String kScrcpyVersion = '4.1';

/// Where the server jar is bundled in the Flutter asset bundle.
const String kScrcpyServerAsset = 'assets/scrcpy/scrcpy-server';

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

  /// Nothing has decoded for a while. The picture on screen is stale.
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

  bool get isHealthy => state == DeviceStreamState.live;

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
    AppLogger? logger,
  }) : _logger = logger ?? AppLogger.named('device-stream');

  final AdbService adb;
  final CommandRunner runner;
  final ScrcpyServerBytes serverBytes;

  /// How long the picture may stand still before the stream is called stalled.
  ///
  /// Long enough that a device sitting on a static screen is not accused of
  /// dying — scrcpy still sends frames then, but slowly — and short enough that
  /// a user does not stare at a dead picture wondering.
  final Duration stallTimeout;

  final Duration watchdogInterval;
  final AppLogger _logger;

  static const _devicePath = '/data/local/tmp/chitragupta-scrcpy-server.jar';

  /// Kills scrcpy servers and removes `adb forward` entries left behind by an
  /// earlier run on [serial].
  ///
  /// Both leaks are real and were observed together: on one device the server
  /// had exited while its forward stayed registered, and on another four
  /// servers were alive at once because killing the host-side `adb shell` does
  /// **not** kill the `app_process` it started on the device. Neither is
  /// self-correcting, so every start begins by clearing them.
  Future<int> reapOrphans(String serial) async {
    var reaped = 0;
    final pids = parseOwnedScrcpyPids(
      await adb.processList(serial),
      jarPath: _devicePath,
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

  /// Connects to the tunnel, retrying until the server is really streaming.
  ///
  /// This is subtler than it looks: `adb forward` accepts the host-side TCP
  /// connection **before** the device-side socket exists, then closes it
  /// immediately. A naive "did connect() succeed?" check therefore latches onto
  /// a dead socket and the stream silently never starts. The only reliable
  /// signal is bytes actually arriving, so each attempt waits for the first
  /// chunk and retries if the socket closes empty.
  Future<_ServingConnection?> _connectWhenServing(
    int port, {
    int attempts = 20,
  }) async {
    for (var attempt = 0; attempt < attempts; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      Socket candidate;
      try {
        candidate = await Socket.connect('127.0.0.1', port);
      } on SocketException {
        continue; // Tunnel not up yet.
      }
      candidate.setOption(SocketOption.tcpNoDelay, true);

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
        const Duration(seconds: 2),
        onTimeout: () => null,
      );
      subscription.pause();

      if (chunk != null && chunk.isNotEmpty) {
        return _ServingConnection(candidate, chunk, subscription);
      }
      await subscription.cancel();
      candidate.destroy();
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
  }) async {
    final profile = isEmulatorSerial(serial)
        ? _softwareEncoder
        : _hardwareEncoder;
    final captureSize = maxSize ?? profile.maxSize;
    final captureFps = maxFps ?? profile.maxFps;

    // 0. Clear anything a previous run left running or registered.
    await reapOrphans(serial);

    // 1. Put the server on the device.
    final jar = await serverBytes();
    final hostJar = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'chitragupta-scrcpy-server-$kScrcpyVersion.jar',
    );
    await hostJar.writeAsBytes(jar, flush: true);
    final push = await runner.run(
      CommandRequest(
        executable: adb.sdk.adb.path,
        arguments: ['-s', serial, 'push', hostJar.path, _devicePath],
      ),
    );
    if (!push.ok) {
      throw StateError('Could not deploy scrcpy-server: ${push.stderr.trim()}');
    }

    // 2. Tunnel. adb picks the port so we never collide with a reserved range.
    final scid = (Random().nextInt(
      0x7FFFFFFF,
    )).toRadixString(16).padLeft(8, '0');
    final socketName = 'localabstract:scrcpy_$scid';
    final forward = await runner.run(
      CommandRequest(
        executable: adb.sdk.adb.path,
        arguments: ['-s', serial, 'forward', 'tcp:0', socketName],
      ),
    );
    final localPort = parseForwardedPort(forward.stdout);
    if (!forward.ok || localPort == null) {
      throw StateError(
        'Could not open an adb tunnel: ${forward.stderr.trim()}',
      );
    }

    // 3. Start the server. raw_stream stays OFF: we want scrcpy's per-frame
    //    timestamps and keyframe flags for the MPEG-TS mux.
    final server = await runner.start(
      CommandRequest(
        executable: adb.sdk.adb.path,
        arguments: [
          '-s',
          serial,
          'shell',
          'CLASSPATH=$_devicePath',
          'app_process',
          '/',
          'com.genymobile.scrcpy.Server',
          kScrcpyVersion,
          'scid=$scid',
          'log_level=warn',
          'tunnel_forward=true',
          'audio=false',
          // Loop 36: the control socket. The server accepts connections in the
          // order video, audio, control, so with audio off it is the second
          // connection to the same tunnel.
          'control=true',
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

    // 4. Connect, once the server is actually serving.
    final connection = await _connectWhenServing(localPort);
    if (connection == null) {
      await server.kill();
      await _killDeviceServers(serial, scid);
      await adb.removeForward(serial, localPort);
      throw StateError(
        'scrcpy-server did not start streaming.'
        '${serverLog.isEmpty ? '' : ' Server said: ${serverLog.join(' / ')}'}',
      );
    }
    final socket = connection.socket;

    // 4b. The control socket, on the same tunnel.
    //
    // The server accepts video, then audio, then control; audio is off, so this
    // second connection is the control one. Loop 27's hazard — `adb forward`
    // accepts the host side *before* the device socket exists — cannot bite
    // here in the same way, because the video socket has already proved the
    // device-side listener is up. What it can still do is close on us, so the
    // connection is only accepted if it survives a short grace period, and every
    // later write checks the socket rather than assuming it.
    final control = await _connectControl(localPort);
    if (control == null) {
      _logger.warning(
        'Device $serial: no control socket; input falls back to adb input.',
      );
    }

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

    void report(DeviceStreamState state, String detail) {
      if (state == lastState && state != DeviceStreamState.ended) return;
      lastState = state;
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
      server.exitCode.then((code) {
        _logger.warning('Device $serial scrcpy-server exited with $code.');
        report(
          DeviceStreamState.ended,
          'scrcpy-server exited (code $code).'
          '${serverLog.isEmpty ? '' : ' ${serverLog.last}'}',
        );
      }).catchError((Object _) {}),
    );

    // The watchdog. A frozen picture is otherwise indistinguishable from a
    // device sitting on a static screen.
    final watchdog = Timer.periodic(watchdogInterval, (_) {
      final now = DateTime.now().microsecondsSinceEpoch;
      final sinceFrame = now - mark.arrivalUs;
      if (mark.frames == 0 || sinceFrame <= stallTimeout.inMicroseconds) {
        if (mark.frames > 0) report(DeviceStreamState.live, 'Streaming.');
        return;
      }
      final bytesRecent = now - lastByteUs < stallTimeout.inMicroseconds;
      report(
        DeviceStreamState.stalled,
        bytesRecent
            ? 'The stream is still sending data but no frame has decoded for '
                  '${(sinceFrame / 1000000).round()}s.'
            : 'No data from the device for '
                  '${(sinceFrame / 1000000).round()}s.',
      );
    });

    // 6. Serve MPEG-TS over loopback.
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.listen((request) async {
      // A fresh muxer per consumer: continuity counters and the timestamp base
      // belong to one output stream, and replaying packets to a second consumer
      // would duplicate them.
      final muxer = TsMuxer();
      request.response
        ..bufferOutput = false
        ..headers.contentType = ContentType('video', 'mp2t');
      request.response.add(muxer.tables());
      await request.response.flush();

      Uint8List accessUnitFor(ScrcpyFrame frame) {
        final config = codecConfig;
        // SPS/PPS is republished ahead of every keyframe so the decoder can
        // start from any of them.
        return (frame.isKeyFrame && config != null)
            ? Uint8List.fromList([...config, ...frame.data])
            : frame.data;
      }

      // Start from the cached keyframe when there is one, so a viewer does not
      // wait for the next one.
      var started = false;
      final cached = lastKeyFrame;
      if (cached != null) {
        mark.basePtsUs ??= cached.ptsUs;
        request.response.add(
          muxer.frame(accessUnitFor(cached), cached.ptsUs, keyframe: true),
        );
        await request.response.flush();
        started = true;
      }

      final subscription = frames.stream.listen((frame) {
        if (!started) {
          if (!frame.isKeyFrame) return;
          started = true;
        }
        mark.basePtsUs ??= frame.ptsUs;
        try {
          request.response.add(
            muxer.frame(
              accessUnitFor(frame),
              frame.ptsUs,
              keyframe: frame.isKeyFrame,
            ),
          );
          mark.writtenUs = DateTime.now().microsecondsSinceEpoch;
          request.response.flush();
        } catch (_) {
          // Consumer went away mid-write.
        }
      });
      await request.response.done.catchError((Object _) {});
      await subscription.cancel();
    });

    var stopped = false;
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
      await http.close(force: true);
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
      url: Uri.parse('http://127.0.0.1:${http.port}/live.ts'),
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

  /// Opens the control socket and gives it a moment to prove it survives.
  ///
  /// There is no positive handshake to wait for — the server says nothing on
  /// this socket until asked — so the test is the negative one: a connection
  /// that adb accepted but the device never did closes almost immediately.
  Future<ScrcpyControlConnection?> _connectControl(
    int port, {
    int attempts = 5,
    Duration grace = const Duration(milliseconds: 250),
  }) async {
    for (var attempt = 0; attempt < attempts; attempt++) {
      Socket candidate;
      try {
        candidate = await Socket.connect('127.0.0.1', port);
      } on SocketException {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        continue;
      }
      final connection = ScrcpyControlConnection(candidate, logger: _logger);
      await Future<void>.delayed(grace);
      if (connection.isOpen) return connection;
      await connection.close();
    }
    return null;
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
