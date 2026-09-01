import 'dart:async';

import 'package:fixnum/fixnum.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/process/command_runner.dart';
import '../domain/simulator_backend.dart';
import '../domain/ui_node.dart';
import 'annex_b_splitter.dart';
import 'idb_companion_connection.dart';
import 'idb_companion_locator.dart';
import 'idb_hid_keymap.dart';
import 'idb_proto/idb.pb.dart' as pb;
import 'idb_proto/idb.pbenum.dart' as pbe;
import 'idb_ui_parsing.dart';

/// [SimulatorBackend] over the vendored `idb_companion`, spoken to in gRPC.
///
/// The companion is a single self-contained binary that ships with this app —
/// the `fb-idb` Python client is one consumer of the same API, not a
/// requirement — so nothing here asks the user to install anything.
///
/// One companion per simulator, because `--udid` takes exactly one. They are
/// started lazily on [attach] and outlive individual calls, since starting one
/// costs a process launch and a socket bind that no tap should pay for.
class IdbCompanionBackend implements SimulatorBackend {
  IdbCompanionBackend({
    required this.runner,
    required this.locator,
    AppLogger? logger,
  }) : _logger = logger ?? AppLogger.named('idb');

  final CommandRunner runner;
  final IdbCompanionLocator locator;
  final AppLogger _logger;

  final Map<String, IdbCompanionConnection> _connections = {};

  @override
  String get id => 'idb';

  @override
  String get displayName => 'idb';

  @override
  Future<bool> isAvailable() async => locator.locate() != null;

  @override
  Future<void> attach(String udid) async {
    if (_connections.containsKey(udid)) return;
    final companion = locator.locate();
    if (companion == null) {
      throw CommandException(
        'No idb_companion was found. The simulator can still be listed, '
        'booted and screenshotted, but not mirrored or tapped.',
      );
    }
    _connections[udid] = await IdbCompanionConnection.start(
      runner: runner,
      companion: companion,
      udid: udid,
      logger: _logger,
    );
  }

  /// The connection for [udid], starting one if this is the first call.
  Future<IdbCompanionConnection> _connection(String udid) async {
    await attach(udid);
    return _connections[udid]!;
  }

  @override
  Future<void> detach(String udid) async {
    _readers.remove(udid);
    final connection = _connections.remove(udid);
    await connection?.close();
  }

  @override
  Future<SimulatorScreen?> screen(String udid) async {
    // The accessibility read is the only source that reports the **point**
    // space, which is what taps and element frames are in. `simctl io
    // enumerate` reports pixels, and using those to place a tap on a 3x device
    // puts it three times too far down and right.
    final read = await _describe(udid);
    final screen = read.screen;
    return screen == null ? null : SimulatorScreen(points: screen);
  }

  /// Why the live view does not work with the companion as shipped.
  ///
  /// `GRPCAsyncRequestStream` is backed by NIO's `NIOThrowingAsyncSequence
  /// Producer`, which fatal-errors when a second `AsyncIterator` is created —
  /// and `VideoStreamMethodHandler` makes two: `requiredNext` reads the Start
  /// frame via `first(where:)`, then a `for try await … in requestStream` loop
  /// watches for Stop. The whole companion process aborts on that second read.
  ///
  /// Observed here on v1.5.2: the stream starts, the companion logs
  /// `Created BGRA→NV12 conversion pipeline at w=1206/h=2622`, then dies with
  /// `NIOThrowingAsyncSequenceProducer allows only a single AsyncIterator to
  /// be created`, and this side sees only an HTTP/2 connection error.
  ///
  /// Upstream: facebook/idb#955, open since 2026-08-24, unfixed in v1.5.2. It
  /// affects every multi-frame handler — `install`, `launch --wait-for`,
  /// `record`, `push`, `dap`, `repl` — not just this one. Everything Karmashala
  /// uses from idb is single-frame apart from the video, which is why touch,
  /// typing and the element tree are unaffected.
  static const String kVideoUnavailable =
      'The live view is unavailable: idb_companion crashes when a video '
      'stream is opened (facebook/idb#955, unfixed as of v1.5.2). Touch, '
      'typing and the element tree are unaffected.';

  @override
  Future<SimulatorVideoFeed> startVideo(
    String udid, {
    int fps = 30,
    double? scale,
  }) async {
    final connection = await _connection(udid);

    // The request stream stays open for the life of the feed: the companion
    // treats a client-closed request stream as INVALID_ARGUMENT, and a first
    // message that is not Start as FAILED_PRECONDITION. Stop is how it ends.
    final requests = StreamController<pb.VideoStreamRequest>();
    final start = pb.VideoStreamRequest_Start()
      ..fps = Int64(fps)
      ..format = pbe.VideoStreamRequest_Format.H264
      ..compressionQuality = 1.0;
    if (scale != null) start.scaleFactor = scale;
    requests.add(pb.VideoStreamRequest()..start = start);

    final splitter = AnnexBSplitter();
    final frames = StreamController<VideoAccessUnit>.broadcast();

    // The payload is an unframed byte stream sliced at arbitrary boundaries —
    // the companion hands over whatever chunk its encoder produced, exactly
    // like reading scrcpy's socket — so the access-unit boundaries are ours to
    // find.
    final responses = connection.client.video_stream(requests.stream).listen(
      (response) {
        if (!response.hasPayload()) return;
        final data = response.payload.data;
        if (data.isEmpty) return;
        for (final unit in splitter.add(data)) {
          if (!frames.isClosed) frames.add(unit);
        }
      },
      onError: (Object error) {
        // Quote the companion. A bare gRPC failure says only that the
        // connection went away, which is indistinguishable from a crash.
        final said = connection.recentErrors;
        if (!frames.isClosed) {
          frames.addError(
            CommandException(
              // The companion abort looks like a bare transport failure from
              // here, so name the known cause rather than leaving a reader to
              // conclude their network is broken.
              '${said.any((line) => line.contains('single AsyncIterator')) ? kVideoUnavailable : 'The video stream stopped: $error'}'
              '${said.isEmpty ? '' : '\nidb_companion said:\n${said.join('\n')}'}',
            ),
          );
        }
      },
      onDone: () {
        for (final unit in splitter.flush()) {
          if (!frames.isClosed) frames.add(unit);
        }
        if (!frames.isClosed) frames.close();
      },
    );

    var stopped = false;
    Future<void> stop() async {
      if (stopped) return;
      stopped = true;
      if (!requests.isClosed) {
        requests.add(pb.VideoStreamRequest()..stop = pb.VideoStreamRequest_Stop());
        await requests.close();
      }
      await responses.cancel();
      if (!frames.isClosed) await frames.close();
    }

    return SimulatorVideoFeed(frames: frames.stream, stop: stop);
  }

  @override
  Future<void> tap(String udid, int x, int y) => _sendHid(udid, [
    _press(_touchAt(x, y), pbe.HIDEvent_HIDDirection.DOWN),
    _press(_touchAt(x, y), pbe.HIDEvent_HIDDirection.UP),
  ]);

  @override
  Future<void> swipe(
    String udid, {
    required int fromX,
    required int fromY,
    required int toX,
    required int toY,
    Duration? duration,
  }) {
    final swipe = pb.HIDEvent_HIDSwipe()
      ..start = _point(fromX, fromY)
      ..end = _point(toX, toY);
    if (duration != null) {
      swipe.duration = duration.inMicroseconds / Duration.microsecondsPerSecond;
    }
    return _sendHid(udid, [pb.HIDEvent()..swipe = swipe]);
  }

  @override
  Future<void> inputText(String udid, String text) {
    final keystrokes = hidKeystrokesFor(text);
    if (keystrokes == null) {
      // Refused rather than partially typed. Typing "cafe" when the caller
      // asked for "café" is worse than failing: the caller believes it worked.
      throw CommandException(
        'That text contains a character with no key on the iOS keyboard map, '
        'so none of it was typed.',
      );
    }
    final events = <pb.HIDEvent>[];
    for (final stroke in keystrokes) {
      if (stroke.shift) {
        events.add(_press(_keyAt(kHidLeftShift), pbe.HIDEvent_HIDDirection.DOWN));
      }
      events
        ..add(_press(_keyAt(stroke.usageCode), pbe.HIDEvent_HIDDirection.DOWN))
        ..add(_press(_keyAt(stroke.usageCode), pbe.HIDEvent_HIDDirection.UP));
      if (stroke.shift) {
        events.add(_press(_keyAt(kHidLeftShift), pbe.HIDEvent_HIDDirection.UP));
      }
    }
    return _sendHid(udid, events);
  }

  @override
  Future<void> pressButton(String udid, SimulatorButton button) => _sendHid(
    udid,
    [
      _press(_buttonAt(button), pbe.HIDEvent_HIDDirection.DOWN),
      _press(_buttonAt(button), pbe.HIDEvent_HIDDirection.UP),
    ],
  );

  @override
  Future<UiHierarchy> describeUi(String udid) async =>
      (await _describe(udid)).hierarchy;

  /// Which reader answered last, so the fallback below is paid for once.
  final Map<String, pbe.AccessibilityInfoRequest_Backend> _readers = {};

  /// One accessibility read, in the format that carries the screen bounds.
  ///
  /// Two readers, tried in that order:
  ///
  /// `AXBRIDGE_PERSISTENT` runs **inside** the simulator, so a composed view
  /// reports as the elements the app actually built rather than as one opaque
  /// box, and the reader is kept warm across calls — roughly 0.2s a read
  /// against 3.5s for a fresh spawn.
  ///
  /// `AX` runs on the host and asks the simulator's accessibility server for
  /// the frontmost application. It sees less — a custom cell describing itself
  /// with one label is one element — but it needs nothing spawned in the guest.
  ///
  /// The fallback is not hypothetical: measured against a simulator sitting on
  /// a freshly booted SpringBoard, the guest reader answered
  /// `The axbridge guest reader failed: serve read timed out after 30s with no
  /// data`. A live view that shows no elements at all is worse than one that
  /// shows the assistive-technology view, so a failure downgrades rather than
  /// propagating — and the choice is remembered, so the 30s timeout is paid
  /// once per simulator rather than on every read.
  Future<IdbUiRead> _describe(String udid) async {
    final connection = await _connection(udid);

    Future<IdbUiRead> read(pbe.AccessibilityInfoRequest_Backend backend) async {
      final response = await connection.client.accessibility_info(
        pb.AccessibilityInfoRequest()
          ..format = pbe.AccessibilityInfoRequest_Format.COMPLETE
          ..backend = backend,
      );
      return parseIdbUiRead(response.json);
    }

    final remembered = _readers[udid];
    if (remembered != null) return read(remembered);

    try {
      final detailed = await read(
        pbe.AccessibilityInfoRequest_Backend.AXBRIDGE_PERSISTENT,
      );
      _readers[udid] = pbe.AccessibilityInfoRequest_Backend.AXBRIDGE_PERSISTENT;
      return detailed;
    } on Object catch (error) {
      _logger.info(
        'The in-simulator accessibility reader would not start for $udid '
        '($error); falling back to the host-side one, which sees composed '
        'views as single elements.',
      );
      _readers[udid] = pbe.AccessibilityInfoRequest_Backend.AX;
      return read(pbe.AccessibilityInfoRequest_Backend.AX);
    }
  }

  /// Sends a batch of HID events as one call.
  ///
  /// Batched deliberately: a tap is two events and a typed word is dozens, and
  /// one round trip per event would make typing visibly slow and let another
  /// caller's events interleave with a half-finished keystroke.
  Future<void> _sendHid(String udid, List<pb.HIDEvent> events) async {
    final connection = await _connection(udid);
    await connection.client.hid(Stream.fromIterable(events));
  }

  static pb.Point _point(int x, int y) => pb.Point()
    ..x = x.toDouble()
    ..y = y.toDouble();

  static pb.HIDEvent_HIDPressAction _touchAt(int x, int y) =>
      pb.HIDEvent_HIDPressAction()
        ..touch = (pb.HIDEvent_HIDTouch()..point = _point(x, y));

  static pb.HIDEvent_HIDPressAction _keyAt(int usageCode) =>
      pb.HIDEvent_HIDPressAction()
        ..key = (pb.HIDEvent_HIDKey()..keycode = Int64(usageCode));

  static pb.HIDEvent_HIDPressAction _buttonAt(SimulatorButton button) =>
      pb.HIDEvent_HIDPressAction()..button = _wireButton(button);

  static pb.HIDEvent_HIDButton _wireButton(SimulatorButton button) =>
      pb.HIDEvent_HIDButton()
        ..button = switch (button) {
          SimulatorButton.home => pbe.HIDEvent_HIDButtonType.HOME,
          SimulatorButton.lock => pbe.HIDEvent_HIDButtonType.LOCK,
          SimulatorButton.sideButton => pbe.HIDEvent_HIDButtonType.SIDE_BUTTON,
          SimulatorButton.siri => pbe.HIDEvent_HIDButtonType.SIRI,
          SimulatorButton.applePay => pbe.HIDEvent_HIDButtonType.APPLE_PAY,
        };

  static pb.HIDEvent _press(
    pb.HIDEvent_HIDPressAction action,
    pbe.HIDEvent_HIDDirection direction,
  ) => pb.HIDEvent()
    ..press = (pb.HIDEvent_HIDPress()
      ..action = action
      ..direction = direction);
}
