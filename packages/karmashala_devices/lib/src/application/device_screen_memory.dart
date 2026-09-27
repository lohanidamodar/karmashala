
import 'package:karmashala_core/util.dart';
import '../../devices.dart';

/// The last screen this app read on each device, in memory only and keyed per
/// device, not per caller: a moved screen is stale for whoever holds it.
class DeviceScreenMemory {
  DeviceScreenMemory({required this.clock});

  final Clock clock;

  final Map<String, ScreenObservation> _byDevice =
      <String, ScreenObservation>{};

  /// What was last seen on [deviceId], or null if nothing has been read.
  ScreenObservation? lastLookAt(String deviceId) => _byDevice[deviceId];

  /// Describes a screen that has just been read, **without** filing it: the
  /// pre-tap check must not record the screen it is about to refuse over.
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
