import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/environment_label.dart';
import '../domain/execution_environment.dart';
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

/// How one environment id should be shown to a person.
///
/// Everywhere that holds only an `environmentId` — an agent installation, a
/// project row, a session — and wants to print it. The id is a stable database
/// key and not a name: the local host's is the literal `windows` on every
/// platform (see [localHostEnvironmentId]), so printing it raw is how the
/// settings screen came to label a Mac's agents "windows".
///
/// Falls back to the id when the environment is unknown, which is at least a
/// handle on the row rather than an empty line.
final environmentLabelForIdProvider = Provider.family<String, String>((
  ref,
  environmentId,
) {
  for (final env in ref.watch(environmentsControllerProvider)) {
    if (env.id == environmentId) return environmentLabel(env) ?? environmentId;
  }
  return environmentId;
});
