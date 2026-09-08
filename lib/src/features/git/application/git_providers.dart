import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// The `agentId` a worktree setup pane is opened under.
///
/// A setup command is not an agent, and this is the one place that pretends
/// otherwise. `openAgentTab` is the only route in the app that *starts* a pane
/// on a chosen command — `openTab` takes a shell profile and nothing else —
/// and going through it buys the WSL, SSH and Windows wrapping that
/// `wrapForPty` and `SshTerminalInstance` already do correctly, which is
/// exactly what §17 says must not be re-derived by hand.
///
/// What it costs is that the pane is stored as `agent:` and treated as an agent
/// pane on a restore. That is the safe direction: `shouldRestartOnActivate`
/// excludes agent panes, so a restored setup pane replays nothing and re-runs
/// nothing. The id is namespaced so it can never collide with a registry agent,
/// and `AgentRegistry.byId` answering null for it is a case
/// `AgentPaneLaunch.fromJson` already handles.
const String kWorktreeSetupAgentId = 'karmashala:worktree-setup';

/// Provides the [WorktreeService], wired to the command-runner factory and the
/// environment store.
final worktreeServiceProvider = Provider<WorktreeService>(
  (ref) => WorktreeService(
    runnerFactory: ref.watch(commandRunnerFactoryProvider),
    environmentDao: ref.watch(executionEnvironmentDaoProvider),
    setup: ref.watch(worktreeSetupServiceProvider),
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

/// The setup that runs when a worktree is created.
///
/// Every collaborator is a callback read *inside* itself, so composing this
/// provider opens no database and builds no terminal — the same discipline
/// `onCheckoutMoved` above follows, and the reason `git/` can depend on a
/// setting that lives in `repositories` without importing it into the service.
final worktreeSetupServiceProvider = Provider<WorktreeSetupService>((ref) {
  return WorktreeSetupService(
    runnerFactory: ref.watch(commandRunnerFactoryProvider),
    clock: ref.watch(clockProvider),
    lookup: (repo) {
      // The checkout is matched the way the filesystem does — `Checkout`
      // exists because the same directory reaches this app spelled three ways.
      for (final repository in ref.read(repositoryDaoProvider).getAll()) {
        if (Checkout(repository.path) != Checkout(repo)) continue;
        return (
          repositoryId: repository.id,
          setup: ref.read(worktreeSetupDaoProvider).get(repository.id),
        );
      }
      // Not a recorded checkout. Nothing to look a setting up by, and not an
      // error: `worktree_create` can be pointed at a path a scan has not been
      // to yet.
      return null;
    },
    record: (report) {
      ref.read(worktreeSetupDaoProvider).record(report);
      ref.read(worktreeSetupRevisionProvider.notifier).bump();
    },
    // The pane itself is opened by the one route both this and the Flutter
    // loop take. See `visibleCommandOpenerProvider` for why it was extracted
    // rather than copied.
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
