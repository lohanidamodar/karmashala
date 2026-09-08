import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/process/command_runner_factory.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../environments/domain/execution_environment.dart';
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
class FlutterSdkReadings extends Notifier<Map<String, FlutterSdkReading>> {
  @override
  Map<String, FlutterSdkReading> build() => const <String, FlutterSdkReading>{};

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
