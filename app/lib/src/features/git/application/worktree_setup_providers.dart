import 'package:riverpod/riverpod.dart';

import 'package:karmashala_git/git.dart';
import '../data/worktree_setup_data.dart';

export '../data/worktree_setup_data.dart'
    show WorktreeSetupData, worktreeSetupDataProvider;

/// Re-reads [ref]'s provider whenever a setup or a verdict changed, here or at
/// another client — nothing polls (§19).
WorktreeSetupData _following(Ref ref) {
  final data = ref.watch(worktreeSetupDataProvider);
  final listening = data.changes.listen((_) => ref.invalidateSelf());
  ref.onDispose(listening.cancel);
  return data;
}

/// Every configured checkout, by repository id.
final worktreeSetupsProvider = Provider<Map<String, WorktreeSetup>>(
  (ref) => _following(ref).getAll(),
);

/// The recorded verdicts for one checkout's worktrees, newest first.
final worktreeSetupRunsProvider =
    Provider.family<List<WorktreeSetupReport>, String>(
      (ref, repositoryId) => _following(ref).runsFor(repositoryId),
    );

/// The newest worktree creations across every checkout.
final recentWorktreeRunsProvider = Provider<List<WorktreeSetupReport>>(
  (ref) => _following(ref).recentRuns(),
);

/// Writes the setting through the server.
class WorktreeSetupController {
  WorktreeSetupController(this._ref);

  final Ref _ref;

  void save(String repositoryId, WorktreeSetup setup) =>
      _ref.read(worktreeSetupDataProvider).save(repositoryId, setup);

  void clear(String repositoryId) =>
      _ref.read(worktreeSetupDataProvider).clear(repositoryId);
}

final worktreeSetupControllerProvider = Provider<WorktreeSetupController>(
  WorktreeSetupController.new,
);
