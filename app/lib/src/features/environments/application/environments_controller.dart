import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/process.dart';
import 'environment_discovery_provider.dart';
import 'environment_providers.dart';

/// Holds the list of known execution environments — the server's, followed as
/// it changes — and can refresh it by running discovery (this machine and the
/// WSL distributions installed on it) and recording what it found there.
class EnvironmentsController extends Notifier<List<ExecutionEnvironment>> {
  @override
  List<ExecutionEnvironment> build() {
    final data = ref.watch(environmentsDataProvider);
    final environments = data.getAll();
    final listening = data.changes.listen((_) => state = data.getAll());
    ref.onDispose(listening.cancel);
    return environments;
  }

  /// Runs discovery and records every found environment at the server.
  Future<List<ExecutionEnvironment>> discoverAndPersist() async {
    final discovered = await ref
        .read(environmentDiscoveryServiceProvider)
        .discover();
    final data = ref.read(environmentsDataProvider);
    for (final env in discovered) {
      await data.put(env);
    }
    return state = data.getAll();
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
