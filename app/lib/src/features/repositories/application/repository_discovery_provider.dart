import 'package:riverpod/riverpod.dart';

import '../../../core/process/command_runner_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../data/repository_discovery_service.dart';
import 'package:karmashala_git/repositories.dart';

/// Provides the repository discovery service, routing to local filesystem
/// for local/WSL and remote SSH command runner for SSH environments.
final repositoryDiscoveryServiceProvider = Provider<RepositoryDiscoveryService>(
  (ref) => EnvironmentAwareRepositoryDiscoveryService(
    localDiscovery: const LocalRepositoryDiscoveryService(),
    runnerFactory: ref.watch(commandRunnerFactoryProvider),
    environments: ref.watch(executionEnvironmentDaoProvider),
  ),
);
