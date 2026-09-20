import 'package:riverpod/riverpod.dart';

import '../../../core/process/command_runner_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../repositories/application/repository_discovery_provider.dart';
import '../../repositories/application/repository_providers.dart';
import 'project_providers.dart';
import 'project_service.dart';

/// Provides the [ProjectService] use-case, wired from its collaborators.
final projectServiceProvider = Provider<ProjectService>(
  (ref) => ProjectService(
    projectDao: ref.watch(projectDaoProvider),
    repositoryDao: ref.watch(repositoryDaoProvider),
    discovery: ref.watch(repositoryDiscoveryServiceProvider),
    ids: ref.watch(idGeneratorProvider),
    clock: ref.watch(clockProvider),
    runnerFactory: ref.watch(commandRunnerFactoryProvider),
  ),
);
