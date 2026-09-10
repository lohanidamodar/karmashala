import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/process.dart';
import '../../git/application/changes_providers.dart';
import '../../repositories/application/repository_providers.dart';
import 'delivery_providers.dart';
import 'session_launcher.dart';
import 'session_providers.dart';

/// Why a branch was left where it was.
enum UpdateRefusal {
  /// An agent is live in the working tree. Folding a base branch into files an
  /// agent is part-way through editing produces a diff neither of them meant.
  stillRunning,

  /// Uncommitted work. `git merge` refuses when it would touch a modified file
  /// and *succeeds* when it would not; refusing both is the consistent rule.
  uncommittedChanges,

  /// Nothing to measure against, so nothing to merge: no `origin/HEAD` and no
  /// parent checkout to fall back on.
  noBase,

  /// The merge stopped with conflicts and was undone — see
  /// [DeliveryUpdateService.updateFromBase] for why it is not left to finish.
  conflicted,

  /// The conflicting merge could not even be undone — the only outcome that
  /// leaves the tree changed, so the sentence has to say it is mid-merge.
  conflictedAndStuck,

  sessionGone,
}

/// What [DeliveryUpdateService.updateFromBase] did.
class UpdateOutcome {
  const UpdateOutcome._(this.refusal, {this.base, this.error});

  const UpdateOutcome.updated(String base) : this._(null, base: base);

  const UpdateOutcome.refused(UpdateRefusal reason, {String? base})
    : this._(reason, base: base);

  const UpdateOutcome.failed(Object error) : this._(null, error: error);

  /// Null when the branch moved — or when [error] says why the attempt failed.
  final UpdateRefusal? refusal;

  /// The ref that was, or would have been, merged in.
  final String? base;

  /// What git said, when the merge was attempted and failed for a reason that
  /// is not one of the refusals above.
  final Object? error;

  bool get isUpdated => refusal == null && error == null;

  /// The sentence to put in front of the user.
  String get message => switch (refusal) {
    UpdateRefusal.stillRunning =>
      'The agent is still running in this worktree. Stop it first.',
    UpdateRefusal.uncommittedChanges =>
      'There are uncommitted changes. Commit or discard them first.',
    UpdateRefusal.noBase =>
      'There is no base branch to update from — this checkout has no '
          'origin/HEAD.',
    UpdateRefusal.conflicted =>
      'Updating from ${base ?? 'the base branch'} conflicts. The merge was '
          'undone; ask the agent to resolve it.',
    UpdateRefusal.conflictedAndStuck =>
      'Updating from ${base ?? 'the base branch'} conflicts, and the merge '
          'could not be undone. The working tree is mid-merge.',
    UpdateRefusal.sessionGone => 'This session no longer exists.',
    null =>
      error == null ? 'Updated from ${base ?? 'the base branch'}.' : '$error',
  };
}

/// Brings a session's branch level with its base — the app's own operation, not
/// a prompt, and it fails closed on a live agent, a dirty tree or a conflict.
class DeliveryUpdateService {
  DeliveryUpdateService(this._ref);

  final Ref _ref;

  Future<UpdateOutcome> updateFromBase(String sessionId) async {
    final session = _ref.read(sessionDaoProvider).getById(sessionId);
    if (session == null || session.isArchived) {
      return const UpdateOutcome.refused(UpdateRefusal.sessionGone);
    }
    final repository = _ref
        .read(repositoryDaoProvider)
        .getById(session.repositoryId);
    if (repository == null) {
      return const UpdateOutcome.refused(UpdateRefusal.sessionGone);
    }
    if (_ref.read(sessionLauncherProvider).livePaneFor(sessionId) != null) {
      return const UpdateOutcome.refused(UpdateRefusal.stillRunning);
    }

    // The same reading the strip drew its `Update` button from: re-deriving
    // the base could merge a different ref from the one the user was seeing.
    final delivery = await _ref.read(
      sessionLocalDeliveryProvider(sessionId).future,
    );
    final base = delivery.baseBranch;
    if (base == null) {
      return const UpdateOutcome.refused(UpdateRefusal.noBase);
    }

    final directory = session.worktree ?? repository.path;
    final changes = _ref.read(changesServiceProvider);
    try {
      // Read again rather than trusting `delivery.dirtyFiles`, which is as old
      // as the last poll: this is the check that protects unrecorded work.
      if ((await changes.changes(directory)).isNotEmpty) {
        return const UpdateOutcome.refused(UpdateRefusal.uncommittedChanges);
      }
      await changes.mergeRef(directory, base);
    } catch (error) {
      // MERGE_HEAD is left behind whichever way a merge stopped, so the abort
      // is tried either way: a successful one means there was a conflict.
      final restored = await changes.abortMerge(directory);
      if (restored) {
        return UpdateOutcome.refused(UpdateRefusal.conflicted, base: base);
      }
      if (await _isMidMerge(directory)) {
        return UpdateOutcome.refused(
          UpdateRefusal.conflictedAndStuck,
          base: base,
        );
      }
      return UpdateOutcome.failed(error);
    }
    return UpdateOutcome.updated(base);
  }

  /// Whether the working tree still has a merge in progress — asked only after
  /// an abort failed. A probe that throws answers "no", not a second failure.
  Future<bool> _isMidMerge(EnvironmentPath directory) async {
    try {
      final head = await _ref
          .read(changesServiceProvider)
          .revParse(directory, 'MERGE_HEAD');
      return head != null;
    } catch (_) {
      return false;
    }
  }
}

final deliveryUpdateServiceProvider = Provider<DeliveryUpdateService>(
  DeliveryUpdateService.new,
);
