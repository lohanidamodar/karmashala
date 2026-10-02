import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:riverpod/riverpod.dart';

import '../data/flutter_data.dart';

/// A project's run configurations as the server keeps them. Asked for when a
/// surface shows them and invalidated after an edit here; an agent's edit
/// shows on the next look.
final flutterRunConfigsProvider = FutureProvider.autoDispose
    .family<List<FlutterRunConfiguration>, String>(
      (ref, projectId) => ref.watch(flutterDataProvider).runConfigs(projectId),
    );

/// Running a checkout and editing its project's run configurations, asked of
/// the server — what the run bar does, so the bar never reaches the data
/// layer itself.
class FlutterRunActions {
  FlutterRunActions(this._data);

  final FlutterData _data;

  /// Starts `flutter run` for [checkoutId]; answers where it is running.
  Future<String> start(
    String checkoutId, {
    String? configurationId,
    String? deviceId,
  }) => _data.runStart(
    checkoutId,
    configurationId: configurationId,
    deviceId: deviceId,
  );

  /// Saves [configuration], new or edited; answers it as the server kept it.
  Future<FlutterRunConfiguration> save(FlutterRunConfiguration configuration) =>
      _data.saveRunConfig(configuration);

  /// Deletes the configuration [id] for every checkout of its project.
  Future<void> delete(String id) => _data.deleteRunConfig(id);
}

final flutterRunActionsProvider = Provider<FlutterRunActions>(
  (ref) => FlutterRunActions(ref.watch(flutterDataProvider)),
);
