import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/util.dart';
import '../../../core/util/clock_provider.dart';
import '../domain/screen_observation.dart';
import '../domain/ui_node.dart';

/// The last screen this app read on each device — one record per device, kept
/// only in memory.
///
/// Written by every tool that reads a screen and consulted by the one tool that
/// acts on a coordinate. That is the whole of it: the ingredients for a
/// pre-action check already existed (`device_ui_dump`, `device_find_elements`),
/// and nothing bound them to the tap.
///
/// **Per device, not per caller.** A fingerprint is a fact about the screen,
/// not about who looked: if another agent moved the screen, the coordinate a
/// third one is holding is stale too. Who read it is kept for the sentence,
/// never for the decision.
///
/// Nothing polls it, nothing expires it and nothing sweeps it. A record is
/// overwritten by the next read of that device and consulted only when someone
/// taps a coordinate; its **age** is what the caller is told and what decides
/// whether a mismatch refuses or warns — see [kDeviceLookWindow].
class DeviceScreenMemory {
  DeviceScreenMemory({required this.clock});

  final Clock clock;

  final Map<String, ScreenObservation> _byDevice =
      <String, ScreenObservation>{};

  /// What was last seen on [deviceId], or null if nothing has been read.
  ScreenObservation? lastLookAt(String deviceId) => _byDevice[deviceId];

  /// Describes a screen that has just been read, **without** filing it.
  ///
  /// Split from [file] for one caller: the pre-tap check has to compare the
  /// screen it just read against the last one *before* replacing it, and must
  /// not file anything at all when it refuses — a refusal that recorded the new
  /// screen would let the identical retry straight through.
  ScreenObservation observationOf({
    required String deviceId,
    required UiHierarchy tree,
    required String? app,
    required String? bySessionId,
  }) => ScreenObservation(
    deviceId: deviceId,
    fingerprint: fingerprintOfScreen(tree),
    app: app,
    nodeCount: tree.nodeCount,
    at: clock.nowUtc(),
    bySessionId: bySessionId,
  );

  /// Makes [seen] the last thing this app saw on its device.
  ScreenObservation file(ScreenObservation seen) =>
      _byDevice[seen.deviceId] = seen;

  /// Describes a screen that has just been read and files it.
  ScreenObservation record({
    required String deviceId,
    required UiHierarchy tree,
    required String? app,
    required String? bySessionId,
  }) => file(
    observationOf(
      deviceId: deviceId,
      tree: tree,
      app: app,
      bySessionId: bySessionId,
    ),
  );

  void forget(String deviceId) => _byDevice.remove(deviceId);

  void clear() => _byDevice.clear();
}

final deviceScreenMemoryProvider = Provider<DeviceScreenMemory>(
  (ref) => DeviceScreenMemory(clock: ref.watch(clockProvider)),
);
