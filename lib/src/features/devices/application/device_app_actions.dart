import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../domain/device_driver.dart';
import 'device_claims.dart';
import 'device_fleet.dart';

/// **Install, launch and force-stop, from the window.**
///
/// The same three verbs `device_install_app`, `device_launch_app` and
/// `device_terminate_app` offer an agent, resolved the same way: a
/// [DeviceDriver] out of the [DeviceFleet], the capability checked, then the
/// device taken through [DeviceClaims]. There is no second path to a device
/// here and no call to a tool from the UI — this is the layer the tools
/// themselves sit on.
///
/// **The claim is what makes this safe to add.** An agent mid-test-run holds
/// the phone, and a person cold-restarting the app underneath it would break
/// the run in a way neither of them could see. So the window takes a driver the
/// way `DeviceControlTools._driverToDrive` does, in the same order and for the
/// same reasons: the driver first, so the claim is keyed on the canonical id
/// and two names for one phone collide; the capability next, so a device that
/// cannot do the thing is not held while being told so.
///
/// **The window claims nothing of its own.** It passes a null session id, which
/// [DeviceClaims.claim] treats as the launcher: it respects a standing claim
/// and takes none. A person is at the machine and is not a session that can
/// lapse, so a claim in their name would have no holder to name and no end.
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

  /// Resolves, checks, claims, acts — and stamps the answer.
  ///
  /// Every outcome carries the moment the driver answered (§19). A device
  /// action's result is a *reading*: "installed" is true of the instant it was
  /// said and of no later instant, and a line with no age on it invites the
  /// reader to believe it still holds.
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
      // `DeviceBusy` and `DeviceRefusal` both `toString()` to the sentence they
      // were built with — the holder named, or the reason this device cannot —
      // so neither needs unwrapping to be worth showing.
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
