import 'package:flutter_riverpod/flutter_riverpod.dart';

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
