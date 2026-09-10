import 'dart:io';

import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import 'device_ports.dart';
import 'package:agent_cli/process.dart';
import 'device_providers.dart';
import '../../devices.dart';

/// Whether this machine can have iOS Simulators at all — a fact about the OS,
/// not a probe: `simctl` ships with Xcode, so spawning `xcrun` proves nothing.
final hostCanRunSimulatorsProvider = Provider<bool>((ref) => Platform.isMacOS);

/// `simctl` access, or `null` on a host that cannot have simulators.
final simctlServiceProvider = Provider<SimctlService?>((ref) {
  if (!ref.watch(hostCanRunSimulatorsProvider)) return null;
  final environment = localHostEnvironment(DateTime.now().toUtc());
  return SimctlService(
    runner: ref.watch(deviceCommandRunnerFactoryProvider).forEnvironment(environment),
  );
});

/// Every simulator in the device set. Refresh with `ref.invalidate`. Includes
/// unavailable ones: hiding a row the user made leaves them hunting for it.
final iosSimulatorsProvider = FutureProvider<List<IosSimulator>>((ref) async {
  final simctl = ref.watch(simctlServiceProvider);
  if (simctl == null) return const [];
  return simctl.listSimulators();
});

/// The simulator the pane is showing, by udid.
final selectedSimulatorUdidProvider =
    NotifierProvider<SelectedSimulatorUdid, String?>(
      SelectedSimulatorUdid.new,
    );

class SelectedSimulatorUdid extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? udid) => state = udid;
}

/// The selected simulator, falling back to the only booted one — booting
/// exactly one has already said which is meant. With several, the choice is.
final selectedSimulatorProvider = Provider<IosSimulator?>((ref) {
  final simulators = ref.watch(iosSimulatorsProvider).asData?.value ?? const [];
  if (simulators.isEmpty) return null;
  final chosen = ref.watch(selectedSimulatorUdidProvider);
  if (chosen != null) {
    for (final simulator in simulators) {
      if (simulator.udid == chosen) return simulator;
    }
  }
  final booted = simulators.where((s) => s.state.isReady).toList();
  return booted.length == 1 ? booted.single : null;
});

/// The live-view backend, or `null` when this build has no WebDriverAgent. One
/// per session: it owns the installed runner, and a fresh one re-handshakes.
final simulatorBackendProvider = Provider<WdaBackend?>((ref) {
  if (!ref.watch(hostCanRunSimulatorsProvider)) return null;
  final simctl = ref.watch(simctlServiceProvider);
  if (simctl == null) return null;
  final locator = WdaLocator();
  if (locator.locate() == null) return null;
  final environment = localHostEnvironment(DateTime.now().toUtc());
  final backend = WdaBackend(
    runner: ref.watch(deviceCommandRunnerFactoryProvider).forEnvironment(environment),
    simctl: simctl,
    locator: locator,
  );
  // Otherwise the runner keeps :8100 and :9100 against the next simulator. It
  // is asked what it attached to — a dispose callback may not read a provider.
  ref.onDispose(backend.detachAll);
  return backend;
});

/// What a simulator pane can offer right now — not one bit: `simctl` manages,
/// and only the backend adds touch, typing and the element tree.
enum SimulatorCapability {
  /// Listing, booting, screenshots, app lifecycle, logs. Always, on macOS.
  manage,

  /// Live video, touch, typing, hardware buttons, the accessibility tree.
  interact,
}

/// The capabilities available, and why any are missing.
class SimulatorSupport {
  const SimulatorSupport({required this.capabilities, this.missingReason});

  final Set<SimulatorCapability> capabilities;

  /// A sentence for the user when something is missing, or null when nothing
  /// is. Names the thing to install rather than saying "unsupported".
  final String? missingReason;

  bool has(SimulatorCapability capability) => capabilities.contains(capability);
}

final simulatorSupportProvider = Provider<SimulatorSupport>((ref) {
  if (!ref.watch(hostCanRunSimulatorsProvider)) {
    return const SimulatorSupport(
      capabilities: {},
      missingReason: 'iOS Simulators need macOS and Xcode.',
    );
  }
  if (ref.watch(simulatorBackendProvider) == null) {
    return const SimulatorSupport(
      capabilities: {SimulatorCapability.manage},
      // Named with the reason: simctl genuinely has no touch injection, and
      // there is nothing to install — a missing WDA means a bad build.
      missingReason:
          'This build has no WebDriverAgent, so a simulator can be listed, '
          'booted and screenshotted but not mirrored or tapped.',
    );
  }
  return const SimulatorSupport(
    capabilities: {SimulatorCapability.manage, SimulatorCapability.interact},
  );
});

/// Writes the `disabled.plist`, or `null` on a host with no simulators.
final simulatorSlimmingServiceProvider = Provider<SimulatorSlimmingService?>((
  ref,
) {
  if (!ref.watch(hostCanRunSimulatorsProvider)) return null;
  final environment = localHostEnvironment(DateTime.now().toUtc());
  return SimulatorSlimmingService(
    runner: ref.watch(deviceCommandRunnerFactoryProvider).forEnvironment(environment),
  );
});

/// The categories the user has chosen to leave running. Ids that no longer
/// name a category are dropped: a removal must not break a saved preference.
final slimmingKeptCategoriesProvider = Provider<Set<SlimmingCategory>>((ref) {
  final ids = ref.watch(
    deviceSlimmingPreferencesProvider.select((s) => s.simulatorSlimmingKept),
  );
  return {for (final id in ids) ?SlimmingCategory.byId(id)};
});

/// Whether starting a simulator will slim it. Applied on start only: launchd
/// reads the plist at boot, so a running simulator has to be restarted.
final slimmingOnStartProvider = Provider<bool>((ref) {
  if (!ref.watch(hostCanRunSimulatorsProvider)) return false;
  return ref.watch(
    deviceSlimmingPreferencesProvider.select((s) => s.simulatorSlimming),
  );
});

class SimulatorTransitions extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  bool isBusy(String udid) => state.contains(udid);

  void _begin(String udid) => state = {...state, udid};
  void _end(String udid) => state = {...state}..remove(udid);

  /// Boots [udid] and waits for its services, then refreshes the list.
  /// `bootAndWait`: `simctl boot` returns while the device is merely starting.
  Future<void> boot(String udid) => _run(udid, (simctl) async {
    await _slim(udid);
    await simctl.bootAndWait(udid);
    // The picker names what the pane is about, so starting a simulator has to
    // move it, or the control above it still says "No device selected".
    ref.read(selectedSimulatorUdidProvider.notifier).select(udid);
    // Only when the user asked for a window: `simctl boot` opens none, so this
    // adds one — the mirror image of the emulator's `-no-window`.
    if (!ref.read(headlessDeviceProvider)) {
      await simctl.showSimulatorWindow(udid);
    }
  });

  /// Writes the device's `disabled.plist` before it is booted. A failure is
  /// logged and swallowed: refusing to boot over an optimisation is an outage.
  Future<void> _slim(String udid) async {
    try {
      // Inside the guard, all of it: reading the setting is a database read,
      // and outside it, a settings store that would not open aborted the boot.
      if (!ref.read(slimmingOnStartProvider)) return;
      final slimming = ref.read(simulatorSlimmingServiceProvider);
      if (slimming == null) return;
      await slimming.slim(
        udid,
        except: ref.read(slimmingKeptCategoriesProvider),
        boot: false,
      );
    } on Object catch (error) {
      AppLogger.named(
        'simulator',
      ).warning('Starting $udid without slimming it reason=$error');
    }
  }

  Future<void> shutdown(String udid) =>
      _run(udid, (simctl) => simctl.shutdown(udid));

  Future<void> _run(
    String udid,
    Future<void> Function(SimctlService simctl) action,
  ) async {
    final simctl = ref.read(simctlServiceProvider);
    if (simctl == null || isBusy(udid)) return;
    _begin(udid);
    try {
      await action(simctl);
    } finally {
      _end(udid);
      // Whether it worked or not, the truth is now on the device set, not in
      // whatever this thought was going to happen.
      ref.invalidate(iosSimulatorsProvider);
    }
  }
}

final simulatorTransitionsProvider =
    NotifierProvider<SimulatorTransitions, Set<String>>(
      SimulatorTransitions.new,
    );

/// Simulators worth offering in a Start picker: available, and not running —
/// 170 exist on this developer's machine, so newest runtime comes first.
final startableSimulatorsProvider = Provider<List<IosSimulator>>((ref) {
  final simulators = ref.watch(iosSimulatorsProvider).asData?.value ?? const [];
  final startable = [
    for (final simulator in simulators)
      if (simulator.isAvailable && simulator.state == SimulatorState.shutdown)
        simulator,
  ]..sort((a, b) {
    final runtime = b.runtime.compareTo(a.runtime);
    return runtime != 0 ? runtime : a.name.compareTo(b.name);
  });
  return List.unmodifiable(startable);
});

/// Simulators that are running now.
final bootedSimulatorsProvider = Provider<List<IosSimulator>>((ref) {
  final simulators = ref.watch(iosSimulatorsProvider).asData?.value ?? const [];
  return List.unmodifiable([
    for (final simulator in simulators)
      if (simulator.state.isReady || simulator.state == SimulatorState.booting)
        simulator,
  ]);
});
