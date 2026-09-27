import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_devices/karmashala_devices.dart';
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

  /// The device's size **in points**, the space taps are sent in. Null when
  /// the backend could not say: input is then unavailable, never guessed.
  final SimulatorScreen? screen;
}

/// What the pane is showing, or why it is not.
sealed class SimulatorLiveViewState {
  const SimulatorLiveViewState();
}

class SimulatorLiveViewIdle extends SimulatorLiveViewState {
  const SimulatorLiveViewIdle();
}

/// Starting is its own state: WebDriverAgent is installed, launched and
/// bootstraps XCTest — 17 seconds warm, and a bare spinner reads as a hang.
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

/// Owns the one simulator live view the pane can show. One at a time: WDA's
/// two servers sit on fixed host ports, so a second fights for :8100/:9100.
class SimulatorLiveViewController extends Notifier<SimulatorLiveViewState> {
  /// Mirrors [state] so `ref.onDispose` has something to tear down: reading
  /// `state` inside a life-cycle callback is forbidden.
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
      // Half resolution, deliberately: WDA streams the full backing store
      // (1206x2622 on an iPhone 17) and the pane throws that detail away.
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

      // Both halves, or neither: naming the simulator while an Android serial
      // stayed selected left the pane with two answers to "which device".
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

/// The last input failure, so a refused tap is visible rather than silent: a
/// gesture is sent and forgotten, or the finger would lag the picture.
class SimulatorInputError extends Notifier<String?> {
  @override
  String? build() => null;

  void report(String message) => state = message;

  void clear() => state = null;
}

final simulatorInputErrorProvider =
    NotifierProvider<SimulatorInputError, String?>(SimulatorInputError.new);
