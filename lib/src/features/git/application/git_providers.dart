import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/quick_open/repo_file_index.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../editor/application/code_editor_providers.dart';
import '../../environments/application/environment_providers.dart';
import 'worktree_service.dart';

/// Provides the [WorktreeService], wired to the command-runner factory and the
/// environment store.
final worktreeServiceProvider = Provider<WorktreeService>(
  (ref) => WorktreeService(
    runnerFactory: ref.watch(commandRunnerFactoryProvider),
    environmentDao: ref.watch(executionEnvironmentDaoProvider),
    // Loop 67: a worktree that has just appeared or vanished is the one change
    // Quick Open's OS watcher cannot see, because the folder is outside every
    // watched root. Both reads happen inside the callback, so composing this
    // service never builds an index.
    onCheckoutMoved: (directory) {
      final root = ref.read(editorActionsProvider).windowsPathFor(directory);
      if (root != null) ref.read(repoFileIndexProvider).invalidate(root);
    },
  ),
);
