import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import 'package:karmashala_devices/devices.dart';
import 'device_claims.dart';
import 'device_fleet.dart';

/// **Install, launch and force-stop, from the window** — the same layer the
/// `device_*` tools sit on: driver, then capability, then [DeviceClaims].
class DeviceAppActions {
  DeviceAppActions(this._ref);

  final Ref _ref;

  /// Puts a build on the device. [path] is an `.apk` or a simulator `.app`; the
  /// driver refuses the other platform's artifact by name.
  Future<DeviceActionOutcome<InstalledApp>> install({
    required String deviceId,
    required String path,
  }) => _act(
    deviceId,
    'install',
    DeviceCapability.installApp,
    (driver) => driver.installApp(path),
  );

  Future<DeviceActionOutcome<LaunchedApp>> launch({
    required String deviceId,
    required String appId,
    String? activity,
  }) => _act(
    deviceId,
    'launch',
    DeviceCapability.appLifecycle,
    (driver) => driver.launchApp(
      appId,
      activity: activity == null || activity.trim().isEmpty
          ? null
          : activity.trim(),
    ),
  );

  Future<DeviceActionOutcome<void>> terminate({
    required String deviceId,
    required String appId,
  }) => _act(
    deviceId,
    'force-stop',
    DeviceCapability.appLifecycle,
    (driver) => driver.terminateApp(appId),
  );

  /// Resolves, checks, claims, acts — and stamps the answer with the moment
  /// the driver said it: "installed" is a reading, true of that instant.
  Future<DeviceActionOutcome<T>> _act<T>(
    String deviceId,
    String verb,
    DeviceCapability capability,
    Future<T> Function(DeviceDriver driver) run,
  ) async {
    try {
      final fleet = await _ref.read(deviceFleetProvider)();
      final driver = await fleet.driverFor(deviceId, verb: verb);
      final missing = driver.missingReason(capability);
      if (missing != null) throw DeviceRefusal('$verb: $missing');
      _ref
          .read(deviceClaimsProvider)
          .claim(deviceId: driver.target.id, sessionId: null, verb: verb);
      final value = await run(driver);
      return DeviceActionOutcome<T>(
        verb: verb,
        value: value,
        at: _ref.read(clockProvider).nowUtc(),
      );
    } on Object catch (error) {
      // `DeviceBusy` and `DeviceRefusal` both `toString()` to the sentence
      // they were built with, so neither needs unwrapping to be shown.
      return DeviceActionOutcome<T>(
        verb: verb,
        problem: '$error',
        at: _ref.read(clockProvider).nowUtc(),
      );
    }
  }
}

/// What a device action answered, and when.
class DeviceActionOutcome<T> {
  const DeviceActionOutcome({
    required this.verb,
    required this.at,
    this.value,
    this.problem,
  });

  final String verb;

  /// The driver's answer, or null when it refused.
  final T? value;

  /// Why it did not happen, in the words the refusal was written in — for a
  /// busy device that is the holder, since when, and what it last did.
  final String? problem;

  /// When the driver answered. Not when it was asked: the gap is the work.
  final DateTime at;

  bool get ok => problem == null;
}

final deviceAppActionsProvider = Provider<DeviceAppActions>(
  DeviceAppActions.new,
);
