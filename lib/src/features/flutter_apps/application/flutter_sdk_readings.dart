import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/process.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../settings/application/settings_controller.dart';
import '../data/flutter_sdk_service.dart';
import '../domain/flutter_sdk.dart';

/// The Flutter SDK reading for each environment somebody has asked about.
///
/// **In memory, and that is the design rather than a shortcut.** §20's rule is
/// that a stored path is state and whether it resolves is a measurement; here
/// there is no state worth storing at all. A located `flutter` is whatever
/// PATH said this morning — a `flutter upgrade`, a channel switch or a
/// distribution reinstall moves it, and nothing about the old answer would
/// help. So the path is never persisted, the reading carries the moment it was
/// taken, and it is taken again when it has aged out.
///
/// **Nothing polls.** A reading happens when a preflight, a launch or a gate
/// asks for one. An environment nobody has run anything in has no row and
/// costs no process.
///
/// The one path that *is* stored is the one a person typed —
/// `Settings.flutterSdkPaths` — and it is read here and handed to the service,
/// which is what makes it beat the PATH probe rather than compete with it.
///
/// **A reading is only as good as the path it was taken against**, so [build]
/// watches that map: changing or clearing a hand-set path empties every held
/// reading, and the next ask measures. Kept here rather than in
/// `SettingsController` so the rule sits beside the readings instead of in
/// every writer of the setting, and selected on the map alone so an unrelated
/// setting — a theme, a window size — costs nothing.
class FlutterSdkReadings extends Notifier<Map<String, FlutterSdkReading>> {
  @override
  Map<String, FlutterSdkReading> build() {
    _handSet = ref.watch(
      settingsControllerProvider.select((settings) => settings.flutterSdkPaths),
    );
    return const <String, FlutterSdkReading>{};
  }

  Map<String, String> _handSet = const {};

  /// What was last read for [environmentId], however old — or null when
  /// nothing has ever looked.
  ///
  /// Null is "we have not looked", which is not "there is no Flutter" (§19).
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
