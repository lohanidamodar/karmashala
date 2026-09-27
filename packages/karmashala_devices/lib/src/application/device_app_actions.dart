import 'package:karmashala_core/util.dart';

import '../../devices.dart';
import 'device_claims.dart';
import 'device_fleet.dart';

/// Who holds [deviceId] right now, as whoever keeps the claims last said, or
/// null. A pane on the server's machine reads the server's claims (slice 4a);
/// anywhere else nobody holds anything a pane could be told about.
typedef DeviceHolderOf = DeviceClaim? Function(String deviceId);

/// **Install, launch and force-stop, from the window** — the same layer the
/// `device_*` tools sit on: driver, then capability, then the claim. A person
/// takes no claim of their own; a device an agent holds is refused in the
/// holder's words unless the person said to act anyway ([override]).
class DeviceAppActions {
  DeviceAppActions({
    required this.fleet,
    required this.clock,
    DeviceHolderOf? holderOf,
  }) : holderOf = holderOf ?? _nobody;

  final DeviceFleetFactory fleet;
  final Clock clock;
  final DeviceHolderOf holderOf;

  static DeviceClaim? _nobody(String _) => null;

  /// Puts a build on the device. [path] is an `.apk` or a simulator `.app`; the
  /// driver refuses the other platform's artifact by name.
  Future<DeviceActionOutcome<InstalledApp>> install({
    required String deviceId,
    required String path,
    bool override = false,
  }) => _act(
    deviceId,
    'install',
    DeviceCapability.installApp,
    override,
    (driver) => driver.installApp(path),
  );

  Future<DeviceActionOutcome<LaunchedApp>> launch({
    required String deviceId,
    required String appId,
    String? activity,
    bool override = false,
  }) => _act(
    deviceId,
    'launch',
    DeviceCapability.appLifecycle,
    override,
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
    bool override = false,
  }) => _act(
    deviceId,
    'force-stop',
    DeviceCapability.appLifecycle,
    override,
    (driver) => driver.terminateApp(appId),
  );

  /// Resolves, checks, consults the holder, acts — and stamps the answer with
  /// the moment the driver said it: "installed" is a reading, true of that
  /// instant.
  Future<DeviceActionOutcome<T>> _act<T>(
    String deviceId,
    String verb,
    DeviceCapability capability,
    bool override,
    Future<T> Function(DeviceDriver driver) run,
  ) async {
    try {
      final driver = await (await fleet()).driverFor(deviceId, verb: verb);
      final missing = driver.missingReason(capability);
      if (missing != null) throw DeviceRefusal('$verb: $missing');
      final held = holderOf(driver.target.id);
      if (held != null && !override) {
        throw DeviceBusy(
          deviceBusyMessage(verb, held, clock.nowUtc()),
          claim: held,
        );
      }
      final value = await run(driver);
      return DeviceActionOutcome<T>(
        verb: verb,
        value: value,
        at: clock.nowUtc(),
      );
    } on DeviceBusy catch (busy) {
      return DeviceActionOutcome<T>(
        verb: verb,
        problem: busy.message,
        heldBy: busy.claim,
        at: clock.nowUtc(),
      );
    } on Object catch (error) {
      // `DeviceRefusal` `toString()`s to the sentence it was built with, so it
      // needs no unwrapping to be shown.
      return DeviceActionOutcome<T>(
        verb: verb,
        problem: '$error',
        at: clock.nowUtc(),
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
    this.heldBy,
  });

  final String verb;

  /// The driver's answer, or null when it refused.
  final T? value;

  /// Why it did not happen, in the words the refusal was written in — for a
  /// busy device that is the holder, since when, and what it last did.
  final String? problem;

  /// The agent's claim that stopped it, when that is why: the pane asks the
  /// person whether to act anyway.
  final DeviceClaim? heldBy;

  /// When the driver answered. Not when it was asked: the gap is the work.
  final DateTime at;

  bool get ok => problem == null;
}
