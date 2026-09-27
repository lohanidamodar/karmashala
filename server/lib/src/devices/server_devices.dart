import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_devices/karmashala_devices.dart';
import 'package:karmashala_store/database.dart';

import '../flutter/flutter_sdk_readings.dart' show kSettingsPreferenceKey;
import 'server_device_claims.dart';

/// The Android devices and iOS simulators **on the server's machine** (slice
/// 4a): its adb, found by the one rule every adb user here follows — the
/// `androidSdkPath` setting, then `ANDROID_HOME`, `ANDROID_SDK_ROOT`, the
/// default SDK, then the PATH (`sdkCandidateRoots`) — its `simctl` on macOS,
/// the fleet the agents' device tools drive, the screen memory their taps are
/// checked against and the one claims registry. Works with every client
/// closed; a client on another machine drives these devices through the
/// server's tools, never its own adb.
class ServerDevices {
  ServerDevices({
    required AppDatabase database,
    required this.claims,
    this.runners = const CommandRunnerFactory(),
    ExecutionEnvironment? environment,
    bool? canRunSimulators,
    SimulatorBackend? Function(SimctlService simctl, CommandRunner runner)?
    backendFor,
    Future<AndroidSdk?> Function(String? handSet)? findSdk,
    this.clock = const SystemClock(),
    this.sdkFreshFor = const Duration(minutes: 1),
    void Function(String message)? log,
  }) : _database = database,
       environment =
           environment ?? localHostEnvironment(DateTime.now().toUtc()),
       _canRunSimulators = canRunSimulators ?? Platform.isMacOS,
       _backendFor = backendFor ?? _wdaBackend,
       _findSdk = findSdk,
       _log = log ?? _silent {
    screens = DeviceScreenMemory(clock: clock);
  }

  final AppDatabase _database;

  /// The one registry the tools, `flutter run` and a pane here answer to.
  final ServerDeviceClaims claims;
  final CommandRunnerFactory runners;

  /// This machine, whose devices these are.
  final ExecutionEnvironment environment;
  final Clock clock;

  /// How long a reading of the SDK is trusted before it is looked for again.
  final Duration sdkFreshFor;

  final bool _canRunSimulators;
  final SimulatorBackend? Function(SimctlService simctl, CommandRunner runner)
  _backendFor;
  final void Function(String message) _log;

  /// Finds the SDK by the one rule, given the hand-set root; a test's own
  /// SDK stands in for the probe.
  final Future<AndroidSdk?> Function(String? handSet)? _findSdk;

  /// The last screen read on each device — what a coordinate tap is checked
  /// against, whichever agent read it.
  late final DeviceScreenMemory screens;

  CommandRunner get _runner => runners.forEnvironment(environment);

  ({String? handSet, DateTime at, AndroidSdk? sdk})? _sdk;
  AdbService? _adb;
  final _booting = <String>{};

  static void _silent(String _) {}

  /// The Android SDK a person named in the settings (`androidSdkPath`), read
  /// on every call — a changed one is looked for at once.
  String? handSetSdk() {
    final raw = _database.readMetadata(kSettingsPreferenceKey);
    if (raw == null) return null;
    try {
      return androidSdkPathIn(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  Map<String, Object?> _settings() {
    final raw = _database.readMetadata(kSettingsPreferenceKey);
    if (raw == null) return const {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? decoded.cast<String, Object?>() : const {};
    } on FormatException {
      return const {};
    }
  }

  /// This machine's Android SDK, or null when there is none.
  Future<AndroidSdk?> sdk() async {
    final handSet = handSetSdk();
    final held = _sdk;
    final now = clock.nowUtc();
    if (held != null &&
        held.handSet == handSet &&
        now.difference(held.at) < sdkFreshFor) {
      return held.sdk;
    }
    final found = await (_findSdk?.call(handSet) ??
        AndroidSdkDiscoveryService(
          runner: _runner,
          environment: environment,
          handSetRoot: handSet,
        ).discover());
    _sdk = (handSet: handSet, at: now, sdk: found);
    return found;
  }

  /// Where the SDK is, for `flutter run`'s `ANDROID_HOME`.
  Future<String?> androidSdkRoot() async => (await sdk())?.root.path;

  /// This machine's adb, or null with no SDK. One service while the SDK
  /// stays where it is: a verification run's recorder sits on it.
  Future<AdbService?> adb() async {
    final found = await sdk();
    if (found == null) return _adb = null;
    final current = _adb;
    if (current != null && current.sdk.adb.path == found.adb.path) {
      return current;
    }
    return _adb = AdbService(runner: _runner, sdk: found);
  }

  /// `simctl`, or null off macOS.
  late final SimctlService? simctl = _canRunSimulators
      ? SimctlService(runner: _runner)
      : null;

  /// The engine that can touch a simulator's screen, or null.
  late final SimulatorBackend? backend = simctl == null
      ? null
      : _backendFor(simctl!, _runner);

  static SimulatorBackend? _wdaBackend(
    SimctlService simctl,
    CommandRunner runner,
  ) {
    final locator = WdaLocator();
    if (locator.locate() == null) return null;
    return WdaBackend(runner: runner, simctl: simctl, locator: locator);
  }

  /// A fleet for one operation: its listings are fresh.
  Future<DeviceFleet> fleet() async => DeviceFleet(
    adb: await adb(),
    simctl: simctl,
    backend: backend,
    bootSimulator: _bootSimulator,
    simulatorIsBusy: _booting.contains,
    // Nothing here keeps a listing: every operation builds its own fleet.
    refreshAndroid: () {},
    refreshSimulators: () {},
  );

  /// Boots [udid] and waits for its services, slimming it first when the
  /// settings say so (as a pane's start does).
  Future<void> _bootSimulator(String udid) async {
    final service = simctl;
    if (service == null || !_booting.add(udid)) return;
    try {
      await _slim(udid);
      await service.bootAndWait(udid);
    } finally {
      _booting.remove(udid);
    }
  }

  Future<void> _slim(String udid) async {
    try {
      final settings = _settings();
      if (settings['simulatorSlimming'] == false) return;
      final kept = settings['simulatorSlimmingKept'] is List
          ? (settings['simulatorSlimmingKept']! as List).whereType<String>()
          : kDefaultSlimmingKept;
      await SimulatorSlimmingService(runner: _runner).slim(
        udid,
        except: {for (final id in kept) ?SlimmingCategory.byId(id)},
        boot: false,
      );
    } on Object catch (error) {
      // An optimisation that failed is not a reason to refuse a boot.
      _log('starting $udid without slimming it ($error)');
    }
  }

  /// Lets the simulator backend go (its runner holds ports).
  Future<void> close() async {
    final engine = backend;
    if (engine is WdaBackend) await engine.detachAll();
  }
}
