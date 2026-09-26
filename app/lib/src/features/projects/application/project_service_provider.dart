import 'package:riverpod/riverpod.dart';

import '../../../core/process/command_runner_providers.dart';
import '../../repositories/application/repository_discovery_provider.dart';
import '../../workspaces/data/workspace_data.dart';
import 'project_service.dart';

/// Provides the [ProjectService] use-case, wired from its collaborators.
final projectServiceProvider = Provider<ProjectService>(
  (ref) => ProjectService(
    workspace: ref.watch(workspaceDataProvider),
    discovery: ref.watch(repositoryDiscoveryServiceProvider),
    runnerFactory: ref.watch(commandRunnerFactoryProvider),
  ),
);
