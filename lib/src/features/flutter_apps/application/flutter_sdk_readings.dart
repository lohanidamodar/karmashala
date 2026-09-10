import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/process.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../settings/application/settings_controller.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';

/// The Flutter SDK reading per environment, in memory only — PATH moves. [build]
/// empties every held reading when a hand-set path changes.
class FlutterSdkReadings extends Notifier<Map<String, FlutterSdkReading>> {
  @override
  Map<String, FlutterSdkReading> build() {
    _handSet = ref.watch(
      settingsControllerProvider.select((settings) => settings.flutterSdkPaths),
    );
    return const <String, FlutterSdkReading>{};
  }

  Map<String, String> _handSet = const {};

  /// What was last read for [environmentId], however old — or null, which is
  /// "we have not looked" and not "there is no Flutter" (§19).
  FlutterSdkReading? cached(String environmentId) => state[environmentId];

  /// Where `flutter` is in [environment], reusing a reading that is still
  /// fresh unless [force] says to look again.
  Future<FlutterSdkReading> readFor(
    ExecutionEnvironment environment, {
    bool force = false,
  }) async {
    final now = ref.read(clockProvider).nowUtc();
    final held = state[environment.id];
    if (!force && held != null && held.isFreshAt(now)) return held;

    final CommandRunnerFactory factory = ref.read(commandRunnerFactoryProvider);
    final reading = await FlutterSdkService(
      runner: factory.forEnvironment(environment),
      environment: environment,
      handSetExecutable: _handSet[environment.id],
    ).read(now);
    state = <String, FlutterSdkReading>{...state, environment.id: reading};
    return reading;
  }

  /// Drops what is known about [environmentId], so the next ask measures.
  void forget(String environmentId) {
    if (!state.containsKey(environmentId)) return;
    state = <String, FlutterSdkReading>{...state}..remove(environmentId);
  }
}

final flutterSdkReadingsProvider =
    NotifierProvider<FlutterSdkReadings, Map<String, FlutterSdkReading>>(
      FlutterSdkReadings.new,
    );
