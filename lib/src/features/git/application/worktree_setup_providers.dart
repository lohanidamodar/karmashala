import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../data/worktree_setup_dao.dart';

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
