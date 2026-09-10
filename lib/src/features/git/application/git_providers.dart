import 'package:riverpod/riverpod.dart';

import '../../../app/shell/quick_open/repo_file_index.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../editor/application/code_editor_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../../explorer/application/checkout.dart';
import '../../repositories/application/repository_providers.dart';
import '../../terminal/application/visible_command_pane.dart';
import 'worktree_service.dart';
import 'worktree_setup_providers.dart';
import 'worktree_setup_service.dart';

/// The `agentId` a setup pane is opened under: `openAgentTab` is the only route
/// with the §17 wrapping, and an `agent:` pane is one a restore never re-runs.
const String kWorktreeSetupAgentId = 'karmashala:worktree-setup';

final worktreeServiceProvider = Provider<WorktreeService>(
  (ref) => WorktreeService(
    runnerFactory: ref.watch(commandRunnerFactoryProvider),
    environmentDao: ref.watch(executionEnvironmentDaoProvider),
    setup: ref.watch(worktreeSetupServiceProvider),
    // A worktree that has just appeared or vanished is the one change Quick
    // Open's OS watcher cannot see. Both reads are inside the callback, so
    // composing this service never builds an index.
    onCheckoutMoved: (directory) {
      final root = ref.read(editorActionsProvider).windowsPathFor(directory);
      if (root != null) ref.read(repoFileIndexProvider).invalidate(root);
    },
  ),
);

/// The setup that runs when a worktree is created. Every collaborator is read
/// *inside* its callback, so composing this provider opens no database and
/// builds no terminal.
final worktreeSetupServiceProvider = Provider<WorktreeSetupService>((ref) {
  return WorktreeSetupService(
    runnerFactory: ref.watch(commandRunnerFactoryProvider),
    clock: ref.watch(clockProvider),
    lookup: (repo) {
      // Matched the way the filesystem does: the same directory reaches this
      // app spelled three ways.
      for (final repository in ref.read(repositoryDaoProvider).getAll()) {
        if (Checkout(repository.path) != Checkout(repo)) continue;
        return (
          repositoryId: repository.id,
          setup: ref.read(worktreeSetupDaoProvider).get(repository.id),
        );
      }
      // Not a recorded checkout, and not an error: `worktree_create` can be
      // pointed at a path no scan has been to yet.
      return null;
    },
    record: (report) {
      ref.read(worktreeSetupDaoProvider).record(report);
      ref.read(worktreeSetupRevisionProvider.notifier).bump();
    },
    // The one route both this and the Flutter loop take.
    openPane: (command) => ref.read(visibleCommandOpenerProvider)(
      VisibleCommand(
        agentId: kWorktreeSetupAgentId,
        argv: command.argv,
        directory: command.worktree,
        environment: command.environment,
        title: command.title,
      ),
    ),
  );
});
