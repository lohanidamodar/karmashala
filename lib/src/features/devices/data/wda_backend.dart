import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karmashala_core/logging.dart';
import '../../../core/process/command_runner.dart';
import '../domain/simulator_backend.dart';
import '../domain/ui_node.dart';
import 'simctl_service.dart';
import 'wda_locator.dart';
import 'wda_ui_parsing.dart';

/// [SimulatorBackend] over WebDriverAgent, running inside the simulator.
///
/// **Why this and not `idb_companion`.** idb's `video_stream` RPC crashes the
/// companion outright — facebook/idb#955, two `AsyncIterator`s over one
/// request stream — so it can drive a simulator but never show one. WDA is also
/// a fifth the size (5.6 MB against 43 MB) and ships for x86_64 as well as
/// arm64, so an Intel Mac gets a live view where idb offered none.
///
/// It is an XCTest bundle that `simctl install`s into the simulator and runs
/// *there*, which is what makes it work against a headless `simctl boot` with
/// no Simulator.app window. Two servers come up with it:
///
/// - `:8100` — JSON over HTTP: the element tree, input, window size.
/// - `:9100` — `multipart/x-mixed-replace` JPEG, which is the live view.
///
/// Measured on an iPhone 17 Pro Max / iOS 26.4: ready 2–7s after launch, 8 fps
/// at defaults and 28 fps once the session settings are raised, full-resolution
/// 1320x2868 frames.
class WdaBackend implements SimulatorBackend {
  WdaBackend({
    required this.runner,
    required this.simctl,
    required this.locator,
    this.httpPort = 8100,
    this.mjpegPort = 9100,
    HttpClient Function()? httpClient,
    AppLogger? logger,
  }) : _newClient = httpClient ?? HttpClient.new,
       _logger = logger ?? AppLogger.named('wda');

  final CommandRunner runner;
  final SimctlService simctl;
  final WdaLocator locator;

  /// WDA's JSON server. One simulator at a time holds it, because the ports are
  /// on the **host** for a simulator — there is no forwarding to scope them.
  final int httpPort;
  final int mjpegPort;

  final HttpClient Function() _newClient;
  final AppLogger _logger;

  String? _attached;
  String? _sessionId;

  @override
  String get id => 'wda';

  @override
  String get displayName => 'WebDriverAgent';

  @override
  Future<bool> isAvailable() async => locator.locate() != null;

  Uri _url(String path) => Uri.parse('http://127.0.0.1:$httpPort$path');

  @override
  Future<void> attach(String udid) async {
    if (_attached == udid) return;
    if (_attached != null) await detach(_attached!);

    final wda = locator.locate();
    if (wda == null) {
      throw CommandException(
        'WebDriverAgent is not installed with this build. The simulator can '
        'still be listed, booted and screenshotted, but not mirrored or '
        'tapped. Run tool/vendor/fetch_wda.sh.',
      );
    }

    await simctl.installApp(udid, wda.appPath);
    // The ports reach the test bundle through `SIMCTL_CHILD_*`, which is how
    // `simctl` passes an environment into the process it launches. Set with
    // `env` rather than on the request, because `CommandRunner` deliberately
    // carries no environment — every runner it has would have to decide what
    // that means across a WSL boundary and an SSH one, for this single caller.
    await runner.run(
      CommandRequest(
        executable: '/usr/bin/env',
        arguments: [
          'SIMCTL_CHILD_USE_PORT=$httpPort',
          'SIMCTL_CHILD_MJPEG_SERVER_PORT=$mjpegPort',
          'xcrun',
          'simctl',
          'launch',
          '--terminate-running-process',
          udid,
          kWdaBundleId,
        ],
      ),
    );

    try {
      await _awaitReady();
    } on CommandException catch (error) {
      // The runner is a *built binary* pinned to one version, so a simulator
      // whose runtime predates it is a real and ordinary way for this to fail —
      // and the timeout alone says only that nothing answered, which reads like
      // a hung machine. Naming the runtime is what turns a runtime swap from a
      // guess into the obvious next step. Looked up only here, on a path that
      // has already spent a minute failing.
      throw CommandException('${error.message}${await _runtimeAdvice(udid)}');
    }
    _attached = udid;
    _logger.info('WebDriverAgent ready for $udid');
  }

  /// A sentence naming the simulator's runtime and the runner's version, or
  /// empty when the runtime cannot be determined — a guess here would send
  /// somebody after the wrong problem.
  Future<String> _runtimeAdvice(String udid) async {
    String? runtimeName;
    try {
      for (final simulator in await simctl.listSimulators()) {
        if (simulator.udid == udid) {
          runtimeName = simulator.runtimeName;
          break;
        }
      }
    } on Object {
      return '';
    }
    if (runtimeName == null) return '';
    final version = locator.locate()?.version;
    return '. That simulator runs $runtimeName, and the vendored '
        'WebDriverAgent${version == null ? '' : ' ($version)'} is a built '
        'binary that does not support every runtime — a simulator on an older '
        'iOS is the usual cause. Boot a newer one, or re-run '
        'tool/vendor/fetch_wda.sh to refresh the runner. Booting, screenshots '
        'and app launches do not need WebDriverAgent and keep working either '
        'way.';
  }

  /// Waits for `/status` to say it is ready.
  ///
  /// Polled rather than slept: measured between 2 and 7 seconds depending on
  /// what else the machine is doing, and a fixed wait is either a stall or a
  /// race.
  Future<void> _awaitReady({
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final deadline = DateTime.now().add(timeout);
    Object? last;
    while (DateTime.now().isBefore(deadline)) {
      try {
        final status = await _get('/status');
        final value = status['value'];
        if (value is Map<String, Object?> && value['ready'] == true) return;
      } on Object catch (error) {
        last = error;
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    throw CommandException(
      'WebDriverAgent did not come up within ${timeout.inSeconds}s'
      '${last == null ? '' : ': $last'}',
    );
  }

  /// The session id, creating one if there is none.
  ///
  /// Most reads need no session — `/status` and `/source` are served without
  /// one — but input and settings do, and creating it costs a round trip that
  /// no tap should pay for.
  Future<String> _session() async {
    final existing = _sessionId;
    if (existing != null) return existing;
    final response = await _post('/session', {
      'capabilities': {
        'alwaysMatch': {'platformName': 'iOS'},
      },
    });
    final value = response['value'];
    final id = value is Map<String, Object?> ? value['sessionId'] : null;
    if (id is! String || id.isEmpty) {
      throw CommandException('WebDriverAgent would not open a session');
    }
    return _sessionId = id;
  }

  @override
  Future<void> detach(String udid) async {
    final session = _sessionId;
    _sessionId = null;
    if (session != null) {
      try {
        await _delete('/session/$session');
      } on Object {
        // The session dies with the runner anyway.
      }
    }
    if (_attached != udid) return;
    _attached = null;
    try {
      await simctl.terminateApp(udid, kWdaBundleId);
    } on Object catch (error) {
      // Every kind, not just CommandException: `simctl` reports a refusal as a
      // StateError, which escaped this and took the ordered shutdown with it —
      // `detachAll` runs from a provider's dispose during quit.
      _logger.info('WebDriverAgent was already gone: $error');
    }
  }

  /// Detaches from whatever is attached, if anything.
  ///
  /// For teardown paths that cannot ask another provider which simulator was
  /// in use — see `simulatorBackendProvider`'s `onDispose`.
  Future<void> detachAll() async {
    final attached = _attached;
    if (attached != null) await detach(attached);
  }

  @override
  Future<SimulatorScreen?> screen(String udid) async {
    await attach(udid);
    final source = await _describe();
    final points = source.screen;
    return points == null ? null : SimulatorScreen(points: points);
  }

  @override
  Future<UiHierarchy> describeUi(String udid) async {
    await attach(udid);
    return (await _describe()).hierarchy;
  }

  Future<WdaUiRead> _describe() async {
    final body = await _getRaw('/source?format=json');
    return parseWdaUiRead(body);
  }

  @override
  Future<SimulatorVideoFeed> startVideo(
    String udid, {
    int fps = 30,
    double? scale,
  }) async {
    await attach(udid);
    // Framerate and quality are session settings, not stream parameters: the
    // MJPEG server reads them from the running session, so they have to be set
    // before the picture is opened rather than passed with it.
    try {
      final session = await _session();
      await _post('/session/$session/appium/settings', {
        'settings': {
          'mjpegServerFramerate': fps,
          'mjpegServerScreenshotQuality': 25,
          if (scale != null) 'mjpegScalingFactor': (scale * 100).round(),
        },
      });
    } on Object catch (error) {
      // A stream at the default 8 fps beats no stream.
      _logger.info('WebDriverAgent kept its default stream settings: $error');
    }

    // No proxy and no muxer: this is already `multipart/x-mixed-replace` over
    // loopback HTTP, which is a container the player opens directly. The
    // Android path needs `TsMuxer` and `LoopbackMediaServer` because scrcpy
    // hands over a raw elementary stream; this does not.
    return SimulatorVideoFeed(
      url: Uri.parse('http://127.0.0.1:$mjpegPort'),
      stop: () async {},
    );
  }

  @override
  Future<void> tap(String udid, int x, int y) async {
    await attach(udid);
    final session = await _session();
    await _post('/session/$session/actions', {
      'actions': [
        {
          'type': 'pointer',
          'id': 'finger1',
          'parameters': {'pointerType': 'touch'},
          'actions': [
            {'type': 'pointerMove', 'duration': 0, 'x': x, 'y': y},
            {'type': 'pointerDown', 'button': 0},
            {'type': 'pause', 'duration': 50},
            {'type': 'pointerUp', 'button': 0},
          ],
        },
      ],
    });
  }

  @override
  Future<void> swipe(
    String udid, {
    required int fromX,
    required int fromY,
    required int toX,
    required int toY,
    Duration? duration,
  }) async {
    await attach(udid);
    final session = await _session();
    await _post('/session/$session/wda/dragfromtoforduration', {
      'fromX': fromX,
      'fromY': fromY,
      'toX': toX,
      'toY': toY,
      'duration':
          (duration ?? const Duration(milliseconds: 300)).inMilliseconds / 1000,
    });
  }

  @override
  Future<bool> isLocked(String udid) async {
    await attach(udid);
    final session = await _session();
    final response = await _get('/session/$session/wda/locked');
    // WebDriverAgent is inconsistent about booleans — `isVisible` and
    // `isEnabled` come back as the strings "1" and "0" — so this accepts both
    // rather than trusting the type.
    final value = response['value'];
    return value == true || value == 1 || value == '1';
  }

  @override
  Future<void> setLocked(String udid, {required bool locked}) async {
    await attach(udid);
    final session = await _session();
    await _post(
      '/session/$session/wda/${locked ? 'lock' : 'unlock'}',
      const {},
    );
  }

  @override
  Future<void> inputText(String udid, String text) async {
    await attach(udid);
    final session = await _session();
    // Whole strings, not a keycode table: WDA types through XCUITest, so
    // anything the iOS keyboard can produce travels as itself. That is why
    // there is no HID map here and no refusal for accented letters or emoji.
    await _post('/session/$session/wda/keys', {
      'value': [text],
    });
  }

  /// The USB HID **keyboard** usage page. WebDriverAgent's
  /// `performIoHidEvent` also reaches the consumer page (`0x0C`), which is
  /// where volume and Siri live, but nothing routed here needs it: those are
  /// hardware buttons, and [pressButton] owns those.
  static const int _hidKeyboardPage = 0x07;

  @override
  Future<void> pressKey(String udid, SimulatorKey key) async {
    await attach(udid);
    final session = await _session();
    // Session-level, unlike `/wda/homescreen`: the route only exists under a
    // session, and asking the server for it answers "unknown command".
    //
    // The duration is what the device sees the key held for, so it has to be
    // long enough for the press to register and short enough not to trip
    // auto-repeat. 10 ms was measured working for arrows, Backspace, Escape and
    // Return against WebDriverAgent 16.11.4 on an iOS 18.2 simulator; the call
    // blocks for it, which is why it is not larger.
    await _post('/session/$session/wda/performIoHidEvent', {
      'page': _hidKeyboardPage,
      'usage': key.hidUsage,
      'durationSeconds': 0.01,
    });
  }

  @override
  Future<void> pressButton(String udid, SimulatorButton button) async {
    await attach(udid);
    switch (button) {
      case SimulatorButton.home:
        // Server-level, not session-level: `/session/<id>/wda/homescreen` is
        // not a route, and asking for it answers "unknown command".
        await _post('/wda/homescreen', const {});
      case SimulatorButton.lock:
        await setLocked(udid, locked: true);
      case SimulatorButton.sideButton:
      case SimulatorButton.siri:
      case SimulatorButton.applePay:
        throw CommandException(
          'WebDriverAgent has no ${button.name} button. Home and lock are the '
          'two it can press.',
        );
    }
  }

  // ---------------------------------------------------------------- HTTP

  Future<Map<String, Object?>> _get(String path) async =>
      _decode(await _getRaw(path));

  Future<String> _getRaw(String path) async {
    final client = _newClient();
    try {
      final response = await (await client.getUrl(_url(path))).close();
      return await response.transform(utf8.decoder).join();
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, Object?>> _post(
    String path,
    Map<String, Object?> body,
  ) async {
    final client = _newClient();
    try {
      final request = await client.postUrl(_url(path));
      request.headers.contentType = ContentType.json;
      // `contentLength` set explicitly, because Dart otherwise sends the body
      // chunked and WDA's server answers `Transfer-Encoding is not supported`
      // to every POST — which is every input command.
      final payload = utf8.encode(jsonEncode(body));
      request.contentLength = payload.length;
      request.add(payload);
      final response = await request.close();
      final decoded = _decode(await response.transform(utf8.decoder).join());
      // WDA answers 200 with an `error` in the body rather than a status code,
      // so a bare status check would read every refusal as a success.
      final value = decoded['value'];
      if (value is Map<String, Object?> && value['error'] != null) {
        throw CommandException(
          'WebDriverAgent refused $path: ${value['message'] ?? value['error']}',
        );
      }
      return decoded;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _delete(String path) async {
    final client = _newClient();
    try {
      await (await client.deleteUrl(_url(path))).close();
    } finally {
      client.close(force: true);
    }
  }

  Map<String, Object?> _decode(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, Object?> ? decoded : const {};
    } on FormatException {
      return const {};
    }
  }
}
