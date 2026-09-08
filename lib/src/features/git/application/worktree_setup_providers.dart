import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../../terminal/application/pane_exit_signal.dart';
import '../data/worktree_setup_dao.dart';
import 'git_providers.dart';

final worktreeSetupDaoProvider = Provider<WorktreeSetupDao>(
  (ref) => WorktreeSetupDao(ref.watch(databaseProvider)),
);

/// Bumped by every setup write, watched by every read of one.
///
/// The `reviewThreadRevisionProvider` shape, and for the same reason: the
/// writer is not the surface. A setup runs because a session was launched or
/// because an agent called `worktree_create`, and the panel showing the verdict
/// has to notice without asking again on a timer — nothing here polls (§19).
class WorktreeSetupRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state = state + 1;
}

final worktreeSetupRevisionProvider =
    NotifierProvider<WorktreeSetupRevision, int>(WorktreeSetupRevision.new);

/// Turns "running in a pane" into a verdict, when the pane's process stops.
///
/// **Watched, not read.** Riverpod 3 pauses a provider's own subscriptions
/// while nothing listens to it, so an observer nobody watches would hear no
/// pane stop at all — silently, which is the worst failure for something whose
/// whole job is noticing. `AppShell` watches it, beside
/// `sessionLivenessReconcilerProvider`, which documents the same hazard.
///
/// It is the *only* thing here that is not on the worktree-creation path, and
/// it exists because a report that says `running` forever is not a report. Its
/// value never changes, so watching it costs the shell one build; nothing
/// polls (§19).
///
/// **A pane the user closed by hand is never reported as finished**, and that
/// is `PaneExitSignal`'s deliberate rule rather than an omission here: only a
/// process that stopped by itself reaches it. Such a run keeps its `running`
/// verdict, which is honest — nobody observed how it ended.
class WorktreeSetupExitObserver extends Notifier<void> {
  @override
  void build() {
    ref.listen(paneExitProvider, (_, exit) {
      if (exit == null) return;
      // One subscription for every pane in the app, and nearly every exit it
      // sees belongs to something else. `noteExit` is a map lookup that
      // answers null for those and writes nothing.
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
