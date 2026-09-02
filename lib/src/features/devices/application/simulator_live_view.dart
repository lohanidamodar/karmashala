import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../data/mjpeg_stream.dart';
import '../domain/simulator_backend.dart';
import 'device_providers.dart';
import 'ios_device_providers.dart';
import 'simulator_frames.dart';

/// A live view of one simulator, and everything that has to be torn down.
class SimulatorLiveView {
  const SimulatorLiveView({
    required this.udid,
    required this.frames,
    required this.feed,
    this.screen,
  });

  final String udid;

  /// The newest frame of the simulator's screen, repainted as they arrive.
  final SimulatorFrames frames;
  final SimulatorVideoFeed feed;

  /// The device's size **in points**, which is the space taps are sent in.
  /// Null when the backend could not say, in which case input is unavailable
  /// rather than guessed — a tap mapped through the wrong space lands
  /// somewhere the user did not touch and reports success.
  final SimulatorScreen? screen;
}

/// What the pane is showing, or why it is not.
sealed class SimulatorLiveViewState {
  const SimulatorLiveViewState();
}

class SimulatorLiveViewIdle extends SimulatorLiveViewState {
  const SimulatorLiveViewIdle();
}

/// Starting is its own state because it takes a long time and nothing else on
/// screen changes while it happens. WebDriverAgent has to be installed into the
/// simulator, launched, and then bootstrap XCTest — measured at 17 seconds on a
/// warm machine. A spinner with no explanation reads as a hang.
class SimulatorLiveViewStarting extends SimulatorLiveViewState {
  const SimulatorLiveViewStarting(this.udid);
  final String udid;
}

class SimulatorLiveViewRunning extends SimulatorLiveViewState {
  const SimulatorLiveViewRunning(this.view);
  final SimulatorLiveView view;
}

class SimulatorLiveViewFailed extends SimulatorLiveViewState {
  const SimulatorLiveViewFailed(this.udid, this.reason);
  final String udid;
  final String reason;
}

/// Owns the one simulator live view the pane can show.
///
/// One at a time: WebDriverAgent's two servers are on fixed host ports for a
/// simulator — there is no forwarding to scope them — so a second simulator
/// would fight the first for `:8100` and `:9100`.
class SimulatorLiveViewController extends Notifier<SimulatorLiveViewState> {
  /// Mirrors [state] so [ref.onDispose] has something to tear down.
  ///
  /// Reading `state` inside a dispose callback is forbidden — Riverpod asserts
  /// `Cannot use Ref or modify other providers inside life-cycles` — and the
  /// player and the WebDriverAgent session both have to be released when the
  /// container goes, or the runner keeps running inside the simulator holding
  /// :8100 and :9100 against the next one someone opens.
  SimulatorLiveViewState _current = const SimulatorLiveViewIdle();

  @override
  SimulatorLiveViewState build() {
    ref.onDispose(() => _teardown(_current));
    return _current = const SimulatorLiveViewIdle();
  }

  void _set(SimulatorLiveViewState next) => state = _current = next;

  AppLogger get _logger => AppLogger.named('simulator-live');

  Future<void> start(String udid) async {
    final backend = ref.read(simulatorBackendProvider);
    if (backend == null) return;
    if (state is SimulatorLiveViewStarting) return;

    await stop();
    _set(SimulatorLiveViewStarting(udid));

    SimulatorFrames? frames;
    try {
      // Half resolution, deliberately. WebDriverAgent streams the device's
      // full backing store — 1206x2622 on an iPhone 17 — and every frame of it
      // is decoded and uploaded as a new texture thirty times a second. The
      // pane is a few hundred points wide, so that detail is thrown away by the
      // scale down; asking for half cuts the decode and the upload to a quarter
      // and nothing about the picture looks different.
      final feed = await backend.startVideo(udid, scale: 0.5);
      // Read once, here: it costs an accessibility round trip, and it cannot
      // change while the picture is up short of a rotation.
      final screen = await backend.screen(udid);
      frames = SimulatorFrames(MjpegStream.connect(feed.url));
      frames.errors.listen((message) {
        if (_current is SimulatorLiveViewRunning) {
          _set(SimulatorLiveViewFailed(udid, message));
        }
      });

      // Whatever the picture is of is what the picker should name, however the
      // view was started — the row's own Live view button does not go through
      // the picker at all.
      //
      // Both halves, or neither: naming the simulator while an Android serial
      // stayed selected left the pane with two answers to "which device is
      // this about", and the toolbar believed the Android one — so the Stop
      // beside the picker went to a scrcpy stream while the user was looking
      // at an iPhone. Clearing the serial also takes that stream down, through
      // the pane's own `_onSelectionChanged`, which is right: this pane shows
      // one device at a time and the simulator's picture is the one that wins.
      ref.read(selectedDeviceSerialProvider.notifier).select(null);
      ref.read(selectedSimulatorUdidProvider.notifier).select(udid);
      _set(
        SimulatorLiveViewRunning(
          SimulatorLiveView(
            udid: udid,
            frames: frames,
            feed: feed,
            screen: screen,
          ),
        ),
      );
    } on Object catch (error, stack) {
      _logger.warning('The simulator live view would not start', error, stack);
      await frames?.dispose();
      _set(SimulatorLiveViewFailed(udid, '$error'));
    }
  }

  Future<void> stop() async {
    final previous = _current;
    _set(const SimulatorLiveViewIdle());
    await _teardown(previous);
  }

  Future<void> _teardown(SimulatorLiveViewState previous) async {
    if (previous is! SimulatorLiveViewRunning) return;
    final view = previous.view;
    try {
      await view.feed.stop();
    } on Object {
      // The picture is going away either way.
    }
    await view.frames.dispose();
  }
}

final simulatorLiveViewProvider =
    NotifierProvider<SimulatorLiveViewController, SimulatorLiveViewState>(
      SimulatorLiveViewController.new,
    );


/// The last input failure, so a refused tap is visible rather than silent.
///
/// A gesture is sent and forgotten — the sink cannot await it without making
/// the finger lag the picture — so without this a tap that WebDriverAgent
/// refused looks identical to one that landed on nothing.
class SimulatorInputError extends Notifier<String?> {
  @override
  String? build() => null;

  void report(String message) => state = message;

  void clear() => state = null;
}

final simulatorInputErrorProvider =
    NotifierProvider<SimulatorInputError, String?>(SimulatorInputError.new);
