import 'package:agent_cli/process.dart';
import '../../environments/application/environment_resolver.dart';
import '../../environments/data/environments_data.dart';
import 'package:karmashala_git/repositories.dart';

/// A [RepositoryDiscoveryService] that uses the local filesystem for host
/// paths and a command runner for POSIX paths in WSL and SSH environments.
class EnvironmentAwareRepositoryDiscoveryService
    implements RepositoryDiscoveryService {
  const EnvironmentAwareRepositoryDiscoveryService({
    required this.localDiscovery,
    required this.runnerFactory,
    required this.environments,
  });

  final RepositoryDiscoveryService localDiscovery;
  final CommandRunnerFactory runnerFactory;
  final EnvironmentsData environments;

  @override
  Future<List<DiscoveredRepository>> discover(
    EnvironmentPath root, {
    int maxDepth = 5,
  }) async {
    final env = ExecutionEnvironmentResolver(
      environments: environments,
      runners: runnerFactory,
    ).resolveFor(root).environment;
    if (env != null &&
        (env.kind == EnvironmentKind.ssh || env.kind == EnvironmentKind.wsl)) {
      return PosixRepositoryDiscovery(
        runnerFactory.forEnvironment(env),
        environmentName: env.name,
      ).discover(root, maxDepth: maxDepth);
    }
    return localDiscovery.discover(root, maxDepth: maxDepth);
  }
}
