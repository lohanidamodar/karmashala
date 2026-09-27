import 'package:agent_cli/process.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:riverpod/riverpod.dart';

import '../../settings/application/settings_controller.dart';
import '../data/flutter_data.dart';

/// The Flutter SDK readings the server took, per environment — it reads
/// them on its own machine (slice 3d), a hand-set path included. Emptied
/// when a hand-set path changes, so the next ask reads again.
class FlutterSdkReadings extends Notifier<Map<String, FlutterSdkReading>> {
  @override
  Map<String, FlutterSdkReading> build() {
    ref.watch(
      settingsControllerProvider.select((settings) => settings.flutterSdkPaths),
    );
    return const <String, FlutterSdkReading>{};
  }

  /// What was last read for [environmentId], however old — or null, which is
  /// "we have not looked" and not "there is no Flutter" (§19).
  FlutterSdkReading? cached(String environmentId) => state[environmentId];

  /// Where `flutter` is in [environment], asked of the server; [force] reads
  /// again rather than reusing a fresh reading.
  Future<FlutterSdkReading> readFor(
    ExecutionEnvironment environment, {
    bool force = false,
  }) async {
    final reading = await ref
        .read(flutterDataProvider)
        .sdk(environment.id, force: force);
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
