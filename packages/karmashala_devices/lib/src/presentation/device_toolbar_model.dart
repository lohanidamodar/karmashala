import '../application/simulator_live_view.dart';
import '../../devices.dart';

/// Which device the toolbar's power button would shut down. A sealed pair, not
/// two nullables: `simctl shutdown` and `adb emu kill` are different verbs.
sealed class DevicePowerTarget {
  const DevicePowerTarget(this.name);

  /// What the tooltip calls it, so the button says what it will stop.
  final String name;
}

class SimulatorPowerTarget extends DevicePowerTarget {
  const SimulatorPowerTarget(this.udid, super.name);
  final String udid;
}

class AndroidPowerTarget extends DevicePowerTarget {
  const AndroidPowerTarget(super.name);
}

/// The one stream action at the end of the toolbar.
enum PrimaryStreamKind {
  /// An Android live view is coming up: a spinner, nothing to press.
  starting,

  /// A simulator's picture is up (or failed to come up): Stop takes it down.
  stopSimulator,

  /// A simulator is picked and nothing is running: start its live view.
  startSimulator,

  /// An Android live view is running.
  stopAndroid,

  /// Nothing is running: start the selected Android device's live view.
  startAndroid;

  String get label => switch (this) {
    starting => 'Starting the live view',
    stopSimulator || stopAndroid => 'Stop',
    startSimulator || startAndroid => 'Live view',
  };

  bool get stops => this == stopSimulator || this == stopAndroid;
}

/// What the toolbar is about, worked out from the providers' answers alone —
/// no widget, no `ref` — so every branch is testable as a plain function.
class DeviceToolbarModel {
  const DeviceToolbarModel({
    required this.liveSimulator,
    required this.restartableSimulator,
    required this.pickedSimulator,
    required this.powerTarget,
    required this.powerBusy,
    required this.primary,
  });

  factory DeviceToolbarModel.from({
    required List<IosSimulator> bootedSimulators,
    required SimulatorLiveViewState simulatorState,
    required String? chosenSimulator,
    required String? chosenAndroid,
    required AndroidDevice? selected,
    required bool canStopEmulator,
    required bool stoppingEmulator,
    required Set<String> busySimulators,
    required bool starting,
    required bool streaming,
  }) {
    // The simulator whose picture is up, whatever the picker says — every
    // state but idle names one, a failed start included, whose Stop dismisses.
    final liveSimulator = switch (simulatorState) {
      SimulatorLiveViewIdle() => null,
      SimulatorLiveViewStarting(:final udid) => udid,
      SimulatorLiveViewRunning(:final view) => view.udid,
      SimulatorLiveViewFailed(:final udid) => udid,
    };
    // Restarting a *start* is not offered: [SimulatorLiveViewController.start]
    // refuses to interrupt one in flight, so it would be inert for 20 seconds.
    final restartableSimulator = switch (simulatorState) {
      SimulatorLiveViewRunning(:final view) => view.udid,
      SimulatorLiveViewFailed(:final udid) => udid,
      _ => null,
    };
    // The simulator this toolbar is *about* when no live view settles it.
    // Keyed on the explicit choice: the derived one is never null with a phone.
    final pickedSimulator =
        chosenAndroid == null &&
            chosenSimulator != null &&
            bootedSimulators.any((s) => s.udid == chosenSimulator)
        ? chosenSimulator
        : null;
    // What the power button acts on: a simulator on screen or picked wins,
    // then an Android *emulator* — `adb emu kill` could only fail on a phone.
    final liveOrPicked = liveSimulator ?? pickedSimulator;
    final DevicePowerTarget? powerTarget = switch ((liveOrPicked, selected)) {
      (final String udid, _) => SimulatorPowerTarget(
        udid,
        bootedSimulators
                .where((s) => s.udid == udid)
                .map((s) => s.name)
                .firstOrNull ??
            'this simulator',
      ),
      (null, final AndroidDevice device)
          when device.isEmulator && canStopEmulator =>
        AndroidPowerTarget(device.displayName),
      _ => null,
    };
    return DeviceToolbarModel(
      liveSimulator: liveSimulator,
      restartableSimulator: restartableSimulator,
      pickedSimulator: pickedSimulator,
      powerTarget: powerTarget,
      powerBusy:
          stoppingEmulator ||
          (liveOrPicked != null && busySimulators.contains(liveOrPicked)),
      // Ordered by what is *running*, then by what is picked: the pane gives
      // the simulator's picture priority, so Stop means what is up.
      primary: starting
          ? PrimaryStreamKind.starting
          : liveSimulator != null
          ? PrimaryStreamKind.stopSimulator
          : pickedSimulator != null
          ? PrimaryStreamKind.startSimulator
          : streaming
          ? PrimaryStreamKind.stopAndroid
          : PrimaryStreamKind.startAndroid,
    );
  }

  final String? liveSimulator;
  final String? restartableSimulator;
  final String? pickedSimulator;
  final DevicePowerTarget? powerTarget;

  /// Whether the device [powerTarget] names is already on its way down.
  final bool powerBusy;

  final PrimaryStreamKind primary;
}
