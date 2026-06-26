import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/process/command_runner_providers.dart';
import '../../environments/application/environment_providers.dart';
import 'worktree_service.dart';

/// Provides the [WorktreeService], wired to the command-runner factory and the
/// environment store.
final worktreeServiceProvider = Provider<WorktreeService>(
  (ref) => WorktreeService(
    runnerFactory: ref.watch(commandRunnerFactoryProvider),
    environmentDao: ref.watch(executionEnvironmentDaoProvider),
  ),
);
