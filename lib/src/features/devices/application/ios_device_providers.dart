import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/process/command_runner_providers.dart';
import '../../agents/data/agent_discovery_service.dart' show localLoginShell;
import '../../environments/domain/local_environment.dart';
import '../data/idb_service.dart';
import '../data/simctl_service.dart';
import '../domain/ios_simulator.dart';

/// Whether this machine can have iOS Simulators at all.
///
/// Not a capability probe — a fact about the OS. `simctl` ships with Xcode and
/// Xcode is macOS-only, so on Windows and Linux the honest answer is "there are
/// none here", and spawning `xcrun` to rediscover that on every refresh is the
/// same mistake `wsl.exe` was making on a Mac.
final hostCanRunSimulatorsProvider = Provider<bool>((ref) => Platform.isMacOS);

/// `simctl` access, or `null` on a host that cannot have simulators.
final simctlServiceProvider = Provider<SimctlService?>((ref) {
  if (!ref.watch(hostCanRunSimulatorsProvider)) return null;
  final environment = localHostEnvironment(DateTime.now().toUtc());
  return SimctlService(
    runner: ref.watch(commandRunnerFactoryProvider).forEnvironment(environment),
  );
});

/// Every simulator in the device set. Refresh with `ref.invalidate`.
///
/// Includes unavailable ones — a simulator whose runtime is not installed is
/// still a row the user put there, and hiding it leaves them wondering where
/// their device went. [IosSimulator.isAvailable] is what the UI greys out on.
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

/// The selected simulator, falling back to the only booted one.
///
/// The fallback matters on a machine with a hundred of them: a user who has
/// booted exactly one has already said which they mean, and asking again is
/// noise. With none or several booted, the choice is theirs.
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

/// Where `idb` is on this machine, or `null` when it is not.
///
/// Cached for the session rather than re-probed: locating it costs a login
/// shell, and a tool does not appear and disappear while the app is open.
/// A user who has just installed it refreshes the pane, which invalidates this.
final idbInstallationProvider = FutureProvider<IdbInstallation?>((ref) async {
  if (!ref.watch(hostCanRunSimulatorsProvider)) return null;
  final environment = localHostEnvironment(DateTime.now().toUtc());
  return IdbService.discover(
    runner: ref.watch(commandRunnerFactoryProvider).forEnvironment(environment),
    loginShell: localLoginShell(),
  );
});

/// idb access, or `null` when this machine has no idb.
final idbServiceProvider = Provider<IdbService?>((ref) {
  final installation = ref.watch(idbInstallationProvider).asData?.value;
  if (installation == null) return null;
  final environment = localHostEnvironment(DateTime.now().toUtc());
  return IdbService(
    runner: ref.watch(commandRunnerFactoryProvider).forEnvironment(environment),
    installation: installation,
  );
});

/// What a simulator pane can offer right now.
///
/// Split out because the answer is not one bit: `simctl` alone gives a picture
/// of sorts and full app control, and idb is what adds touch, typing and the
/// element tree. A pane that reported a single "supported" flag would either
/// hide everything that works or offer taps that silently do nothing.
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
  if (ref.watch(idbServiceProvider) == null) {
    return const SimulatorSupport(
      capabilities: {SimulatorCapability.manage},
      // Named, and with the reason, because "unsupported" would send someone
      // looking for a bug in the app. simctl genuinely has no touch injection
      // and no way to read the screen — this is not something to be fixed here.
      missingReason:
          'Install idb for the live view and touch control — Xcode alone '
          'cannot mirror a simulator or tap one.\n'
          'brew tap facebook/fb && brew install idb-companion && '
          'pip install fb-idb',
    );
  }
  return const SimulatorSupport(
    capabilities: {SimulatorCapability.manage, SimulatorCapability.interact},
  );
});

/// Simulators this app is currently starting or stopping.
///
/// Held here rather than in the pane because a boot outlives the widget: it
/// takes ten seconds or more, and a user who switches away and back must not
/// come back to a Start button that looks untouched.
class SimulatorTransitions extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  bool isBusy(String udid) => state.contains(udid);

  void _begin(String udid) => state = {...state, udid};
  void _end(String udid) => state = {...state}..remove(udid);

  /// Boots [udid] and waits for its services, then refreshes the list.
  ///
  /// `bootAndWait`, not `boot`: `simctl boot` returns as soon as the device is
  /// *starting*, and a row that flipped to "booted" at that moment would offer
  /// a live view of a simulator that cannot answer yet.
  Future<void> boot(String udid) => _run(udid, (simctl) => simctl.bootAndWait(udid));

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

/// Simulators worth offering in a Start picker: available, and not running.
///
/// A machine can hold a great many of these — this developer's has 170, of
/// which 124 have no installed runtime — so the picker shows only what could
/// actually be started, newest runtime first. Sorting by runtime rather than by
/// name puts the simulators someone is likely to want at the top, instead of
/// alphabetising an iPad next to the iPhone they meant.
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
