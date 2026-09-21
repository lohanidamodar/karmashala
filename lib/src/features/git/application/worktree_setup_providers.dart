import 'package:riverpod/riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../terminal/application/pane_exit_signal.dart';
import '../data/worktree_setup_dao.dart';
import 'package:karmashala_git/git.dart';
import 'git_providers.dart';

final worktreeSetupDaoProvider = Provider<WorktreeSetupDao>(
  (ref) => WorktreeSetupDao(ref.watch(databaseProvider)),
);

/// Bumped by every setup write, watched by every read of one: the writer is not
/// the surface, and nothing here polls (§19).
class WorktreeSetupRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state = state + 1;
}

final worktreeSetupRevisionProvider =
    NotifierProvider<WorktreeSetupRevision, int>(WorktreeSetupRevision.new);

/// Turns "running in a pane" into a verdict. Must be *watched*: Riverpod pauses
/// a provider's subscriptions while nothing listens, and this then hears none.
class WorktreeSetupExitObserver extends Notifier<void> {
  @override
  void build() {
    ref.listen(paneExitProvider, (_, exit) {
      if (exit == null) return;
      // Nearly every exit belongs to something else; `noteExit` is a map lookup
      // that answers null for those and writes nothing.
      ref
          .read(worktreeSetupServiceProvider)
          .noteExit(exit.paneId, exit.exitCode);
    });
  }
}

final worktreeSetupExitObserverProvider =
    NotifierProvider<WorktreeSetupExitObserver, void>(
      WorktreeSetupExitObserver.new,
    );

/// Every configured checkout, by repository id. Watches the revision rather
/// than the table, so a setup that ran while the page is open appears without
/// a reopen and without a timer.
final worktreeSetupsProvider = Provider<Map<String, WorktreeSetup>>((ref) {
  ref.watch(worktreeSetupRevisionProvider);
  return ref.watch(worktreeSetupDaoProvider).getAll();
});

/// The recorded verdicts for one checkout's worktrees, newest first.
final worktreeSetupRunsProvider =
    Provider.family<List<WorktreeSetupReport>, String>((ref, repositoryId) {
      ref.watch(worktreeSetupRevisionProvider);
      return ref.watch(worktreeSetupDaoProvider).runsFor(repositoryId);
    });

/// The newest worktree creations across every checkout.
final recentWorktreeRunsProvider = Provider<List<WorktreeSetupReport>>((ref) {
  ref.watch(worktreeSetupRevisionProvider);
  return ref.watch(worktreeSetupDaoProvider).recentRuns();
});

/// Writes the setting, and tells everything reading it.
class WorktreeSetupController {
  WorktreeSetupController(this._ref);

  final Ref _ref;

  void save(String repositoryId, WorktreeSetup setup) {
    _ref
        .read(worktreeSetupDaoProvider)
        .save(repositoryId, setup, _ref.read(clockProvider).nowUtc());
    _ref.read(worktreeSetupRevisionProvider.notifier).bump();
  }

  void clear(String repositoryId) {
    _ref.read(worktreeSetupDaoProvider).clear(repositoryId);
    _ref.read(worktreeSetupRevisionProvider.notifier).bump();
  }
}

final worktreeSetupControllerProvider = Provider<WorktreeSetupController>(
  WorktreeSetupController.new,
);
