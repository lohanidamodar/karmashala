import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/process.dart';
import 'environment_discovery_provider.dart';
import 'environment_providers.dart';

/// Holds the list of known execution environments and can refresh it by running
/// discovery (Windows host + installed WSL distributions).
class EnvironmentsController extends Notifier<List<ExecutionEnvironment>> {
  @override
  List<ExecutionEnvironment> build() =>
      ref.watch(executionEnvironmentDaoProvider).getAll();

  /// Runs discovery and upserts every found environment, then refreshes state.
  Future<List<ExecutionEnvironment>> discoverAndPersist() async {
    final discovered = await ref
        .read(environmentDiscoveryServiceProvider)
        .discover();
    final dao = ref.read(executionEnvironmentDaoProvider);
    for (final env in discovered) {
      dao.upsert(env);
    }
    state = dao.getAll();
    return state;
  }
}

final environmentsControllerProvider =
    NotifierProvider<EnvironmentsController, List<ExecutionEnvironment>>(
      EnvironmentsController.new,
    );

/// How one environment id should be shown to a person. The id is a database
/// key, not a name: the local host's is the literal `windows` on every platform.
final environmentLabelForIdProvider = Provider.family<String, String>((
  ref,
  environmentId,
) {
  for (final env in ref.watch(environmentsControllerProvider)) {
    if (env.id == environmentId) return environmentLabel(env) ?? environmentId;
  }
  // The local host is the one id whose raw form is a *wrong* answer: a Mac
  // whose environment list had not loaded labelled its agents "windows".
  if (environmentId == localHostEnvironmentId) return localHostEnvironmentName;
  return environmentId;
});
