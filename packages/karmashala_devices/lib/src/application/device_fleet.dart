import 'package:riverpod/riverpod.dart';

import '../../devices.dart';
import 'device_providers.dart';
import 'ios_device_providers.dart';

/// What booting produced.
class BootedDevice {
  const BootedDevice({
    required this.id,
    required this.platform,
    required this.name,
    required this.booted,
    required this.note,
  });

  /// The id every other verb wants — an emulator serial, or a simulator udid.
  /// Not what was passed in: an AVD boots by name, then answers to a serial.
  final String id;
  final DevicePlatform platform;
  final String name;
  final bool booted;
  final String note;
}

/// Every device this machine can drive, and the only place that knows there
/// are two platforms. Built per operation: its memoised listings go stale.
class DeviceFleet {
  DeviceFleet({
    required this.adb,
    required this.simctl,
    required this.backend,
    required this.bootSimulator,
    required this.simulatorIsBusy,
    required this.refreshAndroid,
    required this.refreshSimulators,
  });

  /// adb, or null when no Android SDK was found. Null is a supported state: a
  /// Mac with Xcode and no SDK correctly has no Android devices.
  final AdbService? adb;

  /// `simctl`, or null off macOS.
  final SimctlService? simctl;

  /// The engine that can touch a simulator's screen, or null when this build
  /// ships none; [SimulatorDeviceDriver] makes that a capability, not a crash.
  final SimulatorBackend? backend;

  /// Booting goes through the app's transitions notifier, not straight to
  /// `simctl`: that is what applies slimming and moves the picker onto it.
  final Future<void> Function(String udid) bootSimulator;

  /// Whether the app is already starting or stopping this simulator.
  final bool Function(String udid) simulatorIsBusy;

  /// Told after a lifecycle change, so the pane's listings are re-read rather
  /// than left showing a device that is no longer in that state.
  final void Function() refreshAndroid;
  final void Function() refreshSimulators;

  List<AndroidTarget>? _android;
  List<SimulatorTarget>? _ios;

  Future<List<AndroidTarget>> androidTargets() async {
    final cached = _android;
    if (cached != null) return cached;
    final service = adb;
    if (service == null) return _android = const [];
    return _android = [
      for (final device in await service.listDevices()) AndroidTarget(device),
    ];
  }

  Future<List<SimulatorTarget>> simulatorTargets() async {
    final cached = _ios;
    if (cached != null) return cached;
    final service = simctl;
    if (service == null) return _ios = const [];
    return _ios = [
      for (final simulator in await service.listSimulators())
        SimulatorTarget(simulator),
    ];
  }

  /// AVDs known to the SDK, which are not devices: an AVD is a name that only
  /// exists while the thing is stopped.
  Future<List<Avd>> avds() async => await adb?.listAvds() ?? const [];

  /// The AVD called [name], or null. An AVD is a name that exists whether or
  /// not anything is running, which is exactly why the stop verb needs it.
  Future<Avd?> avdNamed(String name) async {
    final needle = name.trim();
    for (final avd in await avds()) {
      if (avd.name == needle) return avd;
    }
    return null;
  }

  /// Every device on this machine, Android first. The two probes start
  /// together: this is the path every `device_*` call without an id takes.
  Future<List<DeviceTarget>> all() async {
    final (android, simulators) = await (
      androidTargets(),
      simulatorTargets(),
    ).wait;
    return [...android, ...simulators];
  }

  /// Everything that could be driven now.
  Future<List<DeviceTarget>> ready() async => [
    for (final target in await all())
      if (target.isReady) target,
  ];

  /// The device [id] names, whatever state it is in, or null: an adb serial, a
  /// simulator udid, or a simulator name — refused when it picks out two.
  Future<DeviceTarget?> find(String id) async {
    final needle = id.trim();
    if (needle.isEmpty) return null;
    for (final target in await androidTargets()) {
      if (target.id == needle) return target;
    }
    final simulators = await simulatorTargets();
    for (final target in simulators) {
      if (target.id.toLowerCase() == needle.toLowerCase()) return target;
    }
    final byName = [
      for (final target in simulators)
        if (target.simulator.name.toLowerCase() == needle.toLowerCase() ||
            target.label.toLowerCase() == needle.toLowerCase())
          target,
    ];
    if (byName.length == 1) return byName.single;
    if (byName.length > 1) {
      throw DeviceRefusal(
        '"$needle" names ${byName.length} simulators: '
        '${byName.map((t) => '${t.label} (${t.id})').join(', ')}. '
        'Pass the udid of the one you mean.',
      );
    }
    return null;
  }

  /// The device to act on in whatever state — for the verbs whose point is to
  /// act on something not ready. [verb] names the caller in every refusal.
  Future<DeviceTarget> requireTarget(String? id, {required String verb}) async {
    if (id != null && id.trim().isNotEmpty) {
      final found = await find(id);
      if (found != null) return found;
      throw DeviceRefusal('No device is called "$id". ${await _whatThereIs()}');
    }
    final candidates = await ready();
    if (candidates.length == 1) return candidates.single;
    if (candidates.isEmpty) {
      throw DeviceRefusal(
        'No device is ready, so $verb has nothing to act on. '
        '${await _whatThereIs()}',
      );
    }
    throw DeviceRefusal(
      '${candidates.length} devices are ready, so $verb cannot guess which you '
      'mean — pass serial. Options: '
      '${candidates.map((t) => t.summary).join(', ')}.',
    );
  }

  /// The driver for [id], refusing rather than guessing; the id may be omitted
  /// when exactly one is ready. [requireReady] is false for stopped devices.
  Future<DeviceDriver> driverFor(
    String? id, {
    required String verb,
    bool requireReady = true,
  }) async {
    final target = await requireTarget(id, verb: verb);
    if (requireReady) {
      final reason = target.notReadyReason;
      if (reason != null) {
        throw DeviceRefusal('$verb needs a ready device. $reason');
      }
    }
    return driverForTarget(target);
  }

  /// The driver for a device already in hand. The only `switch` on platform in
  /// the codebase above the data layer, and the reason there is only one.
  DeviceDriver driverForTarget(DeviceTarget target) => switch (target) {
    AndroidTarget() => AdbDeviceDriver(
      // Non-null by construction: an Android target can only have come out of
      // a listing this fleet asked adb for.
      adb: adb!,
      target: target,
    ),
    SimulatorTarget() => SimulatorDeviceDriver(
      simctl: simctl!,
      backend: backend,
      target: target,
    ),
  };

  /// Starts a virtual device and waits until it can be talked to. Takes a name
  /// or an id: neither platform boots by the id you drive it with afterwards.
  Future<BootedDevice> boot(String nameOrId) async {
    final wanted = nameOrId.trim();
    if (wanted.isEmpty) {
      throw const DeviceRefusal(
        'device_boot needs a name: an AVD name, an iOS simulator udid, or a '
        'simulator name. list_devices shows all three.',
      );
    }

    switch (await find(wanted)) {
      case final SimulatorTarget simulator:
        return _bootSimulatorTarget(simulator);
      case final AndroidTarget device:
        // The id already names a device adb can see, so it is up. Booting asks
        // for a state, and it is in it.
        return BootedDevice(
          id: device.id,
          platform: DevicePlatform.android,
          name: device.label,
          booted: device.isReady,
          note: device.isReady
              ? '${device.id} is already running.'
              : 'Already running, but not usable: ${device.notReadyReason}',
        );
      case null:
        break;
    }

    // Not a device, so it may be an AVD — a name in a different namespace from
    // every serial and udid above, and one that only exists while stopped.
    final service = adb;
    if (service != null) {
      for (final avd in await avds()) {
        if (avd.name != wanted) continue;
        if (avd.runningSerial case final serial?) {
          return BootedDevice(
            id: serial,
            platform: DevicePlatform.android,
            name: wanted,
            booted: true,
            note: '$wanted is already running as $serial.',
          );
        }
        final serial = await service.bootAvdAndWait(wanted, headless: true);
        refreshAndroid();
        return BootedDevice(
          id: serial,
          platform: DevicePlatform.android,
          name: wanted,
          booted: true,
          note:
              'Booted headless — it has no window of its own. Use '
              'device_screenshot and device_ui_dump to see it.',
        );
      }
    }
    throw DeviceRefusal(
      'Nothing bootable is called "$wanted". ${await _whatIsBootable()}',
    );
  }

  Future<BootedDevice> _bootSimulatorTarget(SimulatorTarget target) async {
    if (!target.simulator.isAvailable) {
      throw DeviceRefusal(
        '${target.label} cannot be booted: its runtime '
        '(${target.simulator.runtimeName}) is not installed. Install it in '
        'Xcode, or boot a simulator list_devices reports as available.',
      );
    }
    if (target.isReady) {
      return BootedDevice(
        id: target.id,
        platform: DevicePlatform.ios,
        name: target.simulator.name,
        booted: true,
        note: '${target.label} is already booted.',
      );
    }
    // The transitions notifier returns silently when a boot is already in
    // flight, which for a tool would be success having done nothing.
    if (simulatorIsBusy(target.id)) {
      throw DeviceRefusal(
        '${target.label} is already being started or stopped by this app. Wait '
        'for that to finish, then call list_devices to see where it got to.',
      );
    }
    await bootSimulator(target.id);
    _ios = null; // The listing this fleet cached is now a lie.
    final after = await find(target.id);
    return BootedDevice(
      id: target.id,
      platform: DevicePlatform.ios,
      name: target.simulator.name,
      booted: after?.isReady ?? false,
      note:
          'Booted headless — simctl opens no window, and this app mirrors it. '
          'Coordinates for device_tap on this device are in POINTS; '
          'device_ui_dump reports them in the right space.',
    );
  }

  /// Shuts a virtual device down, then tells the app its listings are stale.
  /// The refusal for a physical phone is [DeviceDriver.powerOff]'s, not this.
  Future<String> powerOff(DeviceDriver driver) async {
    if (!driver.can(DeviceCapability.powerOff)) {
      throw DeviceRefusal(driver.missingReason(DeviceCapability.powerOff)!);
    }
    if (driver.target is SimulatorTarget && simulatorIsBusy(driver.target.id)) {
      throw DeviceRefusal(
        '${driver.target.label} is already being started or stopped by this '
        'app. Wait for that to finish, then check list_devices.',
      );
    }
    final outcome = await driver.powerOff();
    switch (driver.target) {
      case AndroidTarget():
        _android = null;
        refreshAndroid();
      case SimulatorTarget():
        _ios = null;
        refreshSimulators();
    }
    return outcome;
  }

  /// What exists right now, kept short: not the whole simulator list — 170 of
  /// them pasted into a refusal buries the line that says what went wrong.
  Future<String> _whatThereIs() async {
    final parts = <String>[];
    final android = await androidTargets();
    if (adb == null) {
      parts.add(
        'No Android SDK was found, so no Android device could be listed (set '
        'ANDROID_HOME).',
      );
    } else if (android.isEmpty) {
      parts.add('No Android devices are connected.');
    } else {
      parts.add(
        'Android: '
        '${android.map((t) => '${t.id} (${t.device.state.name})').join(', ')}.',
      );
    }

    if (simctl == null) {
      parts.add(
        'iOS Simulators need macOS with Xcode, and this host has neither.',
      );
    } else {
      final simulators = await simulatorTargets();
      final booted = [
        for (final target in simulators)
          if (target.isReady) target,
      ];
      parts.add(
        booted.isEmpty
            ? 'No simulator is booted (${simulators.length} exist — see '
                  'list_devices, then device_boot one).'
            : 'Booted simulators: '
                  '${booted.map((t) => '${t.label} (${t.id})').join(', ')}.',
      );
    }
    return parts.join(' ');
  }

  Future<String> _whatIsBootable() async {
    final parts = <String>[];
    if (adb == null) {
      parts.add('There is no Android SDK here, so there are no AVDs.');
    } else {
      final stopped = [
        for (final avd in await avds())
          if (!avd.isRunning) avd.name,
      ];
      parts.add(
        stopped.isEmpty
            ? 'No stopped AVDs.'
            : 'AVDs: ${stopped.take(20).join(', ')}'
                  '${stopped.length > 20 ? ', …' : ''}.',
      );
    }
    final bootable = [
      for (final target in await simulatorTargets())
        if (target.simulator.isAvailable &&
            target.simulator.state == SimulatorState.shutdown)
          target.label,
    ];
    parts.add(
      bootable.isEmpty
          ? 'No bootable simulators.'
          : '${bootable.length} bootable simulators, e.g. '
                '${bootable.take(6).join(', ')}. Call list_devices for the '
                'rest.',
    );
    return parts.join(' ');
  }
}

/// Builds a fleet for one operation. See [deviceFleetProvider].
typedef DeviceFleetFactory = Future<DeviceFleet> Function();

/// A **factory**, not a fleet: one cached instance would hand every call the
/// same stale listing. Awaited because a null adb service also means "not yet".
final deviceFleetProvider = Provider<DeviceFleetFactory>((ref) {
  return () async {
    await ref.read(androidSdkProvider.future);
    final transitions = ref.read(simulatorTransitionsProvider.notifier);
    return DeviceFleet(
      adb: ref.read(adbServiceProvider),
      simctl: ref.read(simctlServiceProvider),
      backend: ref.read(simulatorBackendProvider),
      bootSimulator: transitions.boot,
      simulatorIsBusy: transitions.isBusy,
      refreshAndroid: () {
        ref.invalidate(devicesProvider);
        ref.invalidate(avdsProvider);
      },
      refreshSimulators: () => ref.invalidate(iosSimulatorsProvider),
    );
  };
});
