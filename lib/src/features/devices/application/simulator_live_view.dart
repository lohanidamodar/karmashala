import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../core/logging/app_logger.dart';
import '../domain/simulator_backend.dart';
import 'ios_device_providers.dart';

/// A live view of one simulator, and everything that has to be torn down.
class SimulatorLiveView {
  const SimulatorLiveView({
    required this.udid,
    required this.player,
    required this.controller,
    required this.feed,
  });

  final String udid;
  final Player player;
  final VideoController controller;
  final SimulatorVideoFeed feed;
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

    Player? player;
    try {
      final feed = await backend.startVideo(udid);
      player = Player(
        configuration: const PlayerConfiguration(
          // A live view wants the newest frame, not a smooth buffer.
          bufferSize: 256 * 1024,
          logLevel: MPVLogLevel.error,
          protocolWhitelist: ['file', 'tcp', 'http'],
        ),
      );
      final native = player.platform as NativePlayer;
      for (final entry in const {
        'profile': 'low-latency',
        'cache': 'no',
        'demuxer-readahead-secs': '0',
        'demuxer-lavf-analyzeduration': '0',
        'untimed': 'yes',
        'vd-lavc-threads': '1',
        'audio': 'no',
      }.entries) {
        await native.setProperty(entry.key, entry.value);
      }
      final controller = VideoController(player);
      // No demuxer is named: the stream is `multipart/x-mixed-replace`, which
      // libmpv detects on its own. Verified with mpv against a real simulator:
      // `Video --vid=1 (mjpeg 1206x2622)`.
      await player.open(Media(feed.url.toString()));

      _set(
        SimulatorLiveViewRunning(
          SimulatorLiveView(
            udid: udid,
            player: player,
            controller: controller,
            feed: feed,
          ),
        ),
      );
    } on Object catch (error, stack) {
      _logger.warning('The simulator live view would not start', error, stack);
      await player?.dispose();
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
    await view.player.dispose();
  }
}

final simulatorLiveViewProvider =
    NotifierProvider<SimulatorLiveViewController, SimulatorLiveViewState>(
      SimulatorLiveViewController.new,
    );
