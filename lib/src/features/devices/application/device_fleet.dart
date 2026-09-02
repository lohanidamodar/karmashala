import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/adb_device_driver.dart';
import '../data/adb_service.dart';
import '../data/simctl_service.dart';
import '../data/simulator_device_driver.dart';
import '../domain/android_device.dart';
import '../domain/device_driver.dart';
import '../domain/device_target.dart';
import '../domain/ios_simulator.dart';
import '../domain/simulator_backend.dart';
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
  /// Not the same string that was passed in: an AVD is booted by name and then
  /// answers to `emulator-5554`.
  final String id;
  final DevicePlatform platform;
  final String name;
  final bool booted;
  final String note;
}

/// Every device this machine can drive, and the driver for each.
///
/// **The one place that knows there are two platforms.** Callers resolve a
/// [DeviceDriver] from an id here and then speak only [DeviceDriver] — the
/// point of the seam is that nothing above this file contains an
/// `if (isSimulator)`.
///
/// A fleet is built **per operation** rather than held, and that is load-
/// bearing rather than tidy. The two listings below are memoised so that one
/// tool call does not ask adb for the device list four times; a fleet that
/// outlived the call would go on answering from that memo forever. It did, for
/// one revision of this file, and the symptom was precise: `device_boot`
/// started an emulator, reported it booted, and the very next
/// `device_install_app` said "No Android devices are connected" — because the
/// fleet had cached the empty list from before the boot and nothing ever
/// cleared it. A device plugged in, or a simulator booted from Xcode, would
/// have been invisible for the life of the app the same way.
///
/// So the cache lasts exactly as long as a device listing stays true, which is
/// one operation. See [deviceFleetProvider], which hands out a factory rather
/// than an instance for this reason.
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

  /// adb, or null when no Android SDK was found. Null is a supported state, not
  /// a failure: this app runs on Macs with Xcode and no SDK, where "there are
  /// no Android devices" is the correct answer, and throwing over it would take
  /// the simulators down with it.
  final AdbService? adb;

  /// `simctl`, or null off macOS.
  final SimctlService? simctl;

  /// The engine that can touch a simulator's screen, or null when this build
  /// ships none. Passed down to [SimulatorDeviceDriver], which turns it into a
  /// capability rather than a crash.
  final SimulatorBackend? backend;

  /// Booting a simulator goes back through the app's own transitions notifier
  /// rather than straight to `simctl`, and that is deliberate: it is what
  /// applies the user's slimming preference and what moves the device picker
  /// onto the simulator that was just started, so the device an agent booted is
  /// the device the person watching is shown. It is *not* on [DeviceDriver],
  /// because a driver is bound to a device and a device being booted does not
  /// have one yet.
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

  /// The AVD called [name], or null. An AVD is not a device: it is a name that
  /// exists whether or not anything is running, which is exactly why the stop
  /// verb needs it — see [DeviceControlTools] on why a stopped emulator cannot
  /// be named by serial.
  Future<Avd?> avdNamed(String name) async {
    final needle = name.trim();
    for (final avd in await avds()) {
      if (avd.name == needle) return avd;
    }
    return null;
  }

  /// Every device on this machine, Android first.
  ///
  /// The two probes are started together. They are separate tools asking about
  /// separate id namespaces, and this is the path `driverFor` takes for every
  /// `device_*` call that does not name a device — which is most of them — so
  /// serialising it added `adb devices` (41ms here) to `simctl list devices`
  /// (214ms) on every tap, every keystroke and every screenshot in a driving
  /// session. The fleet is rebuilt per operation on purpose, so the cost is
  /// paid every time rather than once.
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

  /// The device [id] names, whatever state it is in, or null.
  ///
  /// Three ways to name one, in order of how unambiguous they are: an adb
  /// serial, a simulator udid, and — only when it picks out exactly one
  /// simulator — a simulator's name. The name is accepted because udids are
  /// unreadable and unmemorable, so a caller working from a task description
  /// ("boot an iPhone 17 Pro") has nothing else to go on. It is refused when
  /// ambiguous rather than guessed: two simulators can share a name across
  /// runtimes, and booting the iOS 17 one when the task meant iOS 26 is a wrong
  /// answer that looks like a right one.
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

  /// The device to act on, in whatever state — for the verbs whose whole point
  /// is to act on something that is not ready.
  ///
  /// [verb] is the caller's own name and goes into every refusal, so whoever
  /// reads the error knows which call was turned down rather than only that
  /// something about devices went wrong.
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

  /// The driver for [id], refusing rather than guessing.
  ///
  /// With exactly one ready device — of either platform — the id can be
  /// omitted, which is what a caller will want almost every time.
  ///
  /// [requireReady] is false only for the verbs that act on a stopped device.
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

  /// Starts a virtual device and waits until it can actually be talked to.
  ///
  /// Takes a **name or an id**, because the two platforms name the thing you
  /// boot differently and neither name is the one you drive afterwards. An AVD
  /// is booted by name and then answers to `emulator-5554`; a simulator is
  /// booted by udid and keeps it. Accepting an AVD name, a udid, or a
  /// simulator's own name means a caller can act on a task description ("start
  /// an iPhone 17 Pro") without a lookup step, and [BootedDevice.id] always
  /// carries the id every other verb wants.
  ///
  /// Not a [DeviceDriver] method: a driver is bound to a device, and the whole
  /// point of booting is that the device is not there to be bound to yet.
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
    // flight for this udid, which for the UI is right — a second click on a
    // spinning button is nothing — but for a tool it would be a call that
    // reported success having done nothing at all.
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
  ///
  /// The work is [DeviceDriver.powerOff]'s — the refusal for a physical phone
  /// lives with the driver that knows it is one — and what is added here is the
  /// refresh, which is a fleet-level fact rather than a device-level one.
  Future<String> powerOff(DeviceDriver driver) async {
    if (!driver.can(DeviceCapability.powerOff)) {
      throw DeviceRefusal(driver.missingReason(DeviceCapability.powerOff)!);
    }
    if (driver.target is SimulatorTarget &&
        simulatorIsBusy(driver.target.id)) {
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

  /// What exists right now, kept short.
  ///
  /// Deliberately not the whole simulator list: this developer's machine has
  /// 170 of them, and pasting all 170 into a refusal buries the one line that
  /// says what went wrong. Booted simulators are named because those are the
  /// ones a caller could have meant; the rest are counted and pointed at
  /// `list_devices`.
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

/// A **factory**, not a fleet.
///
/// Riverpod caches a provider's value, so exposing the fleet directly handed
/// every tool call the same instance — and therefore the same memoised device
/// listing, taken whenever the first call happened to run. See [DeviceFleet]'s
/// class comment for what that actually did. Handing out a factory keeps the
/// expensive things cached (the services, and the SDK discovery future) while
/// the cheap, perishable thing — who is plugged in right now — is asked again
/// for every operation.
///
/// **The await is the second half of the same lesson.** `adbServiceProvider`
/// reads `androidSdkProvider.asData?.value`, which is null in two completely
/// different situations: discovery finished and found no SDK, and discovery has
/// not finished yet. Locating the SDK means *running* `adb --version` and
/// `emulator -version` — process spawns, not a lookup — so on a cold start it
/// is genuinely in flight for a second or two. For the pane that ambiguity is
/// harmless; it renders again when the value lands. For a tool it is not:
/// `list_devices` said "No Android SDK was found" on a machine that has one,
/// which is a confident false statement rather than a delay, and an agent that
/// reads it goes away and does not come back. Observed exactly that way — two
/// consecutive runs against the same machine, one listing the SDK and one
/// denying it, decided only by how long the app had been up. `.future`
/// resolves once and is cached, so the first caller pays for the probe and no
/// one else does.
///
/// The callbacks are how a plain class reaches Riverpod without importing it
/// into its own logic — which is what keeps [DeviceFleet] constructible in a
/// test with three stubs and no container.
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
