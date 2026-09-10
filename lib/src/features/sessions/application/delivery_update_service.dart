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

  /// Uncommitted work. `git merge` refuses outright when the merge would touch
  /// a modified file and *succeeds* when it would not, blending unrecorded
  /// edits into a merge nobody reviewed; refusing both is the only consistent
  /// version.
  uncommittedChanges,

  /// Nothing to measure against, so nothing to merge: no `origin/HEAD` and no
  /// parent checkout to fall back on.
  noBase,

  /// The merge stopped with conflicts and was undone. See
  /// [DeliveryUpdateService.updateFromBase] for why this is not left for the
  /// user to finish.
  conflicted,

  /// The conflicting merge could not even be undone — the rarest outcome and
  /// the only one that leaves the working tree changed, so the sentence the
  /// user reads has to tell them their tree is mid-merge.
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

/// Brings a session's branch level with the base it is measured against.
///
/// **The app's own operation, not a prompt.** "Merge `origin/main` into this
/// branch" has no content for a model to invent — one command, one argument —
/// and the only way to get it wrong is the moment it runs at, which is exactly
/// what an app can check and a prompt cannot be trusted to.
///
/// It fails closed, and each way is a refusal rather than a best effort: a live
/// agent stops it; any uncommitted change stops it, even one git would have
/// merged around, because a button that refuses or silently blends depending on
/// which files are dirty is not one anyone can learn; a conflicting merge is
/// **aborted**, not left for the user, because the strip's `Resolve conflicts`
/// prompt is the better answer and a half-merged index is a job nobody asked
/// for; anything else comes back as [UpdateOutcome.failed] carrying git's own
/// stderr.
///
/// It never fetches: the base is whatever `origin/main` this clone last saw,
/// and a network round trip behind a button labelled `Update` would make a fast
/// local operation intermittently slow for a freshness the strip never claims.
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

    // The same reading the strip drew its `Update` button from: the base it
    // names is the base the "N behind" fact was measured against, and
    // re-deriving it could merge a different ref from the one the user saw.
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
      // A merge that stopped leaves MERGE_HEAD behind whichever way it stopped,
      // so the abort is attempted either way and its answer is what tells the
      // two apart: a successful abort means there was a merge to undo, which is
      // what a conflict looks like.
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

  /// Whether the working tree still has a merge in progress. Asked only after
  /// an abort failed, to tell "there was nothing to abort" from "the abort
  /// itself could not clean up". A probe that throws answers "no": it is only
  /// refining an error message already about to be shown.
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
