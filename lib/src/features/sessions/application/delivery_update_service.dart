import 'package:riverpod/riverpod.dart';

import '../../environments/domain/environment_path.dart';
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
  /// a modified file, and *succeeds* when it would not — leaving the user's
  /// unrecorded edits mixed into a merge they did not review. Refusing both
  /// cases is the only version of this that behaves the same way twice.
  uncommittedChanges,

  /// Nothing to measure against, so nothing to merge: no `origin/HEAD` and no
  /// parent checkout to fall back on.
  noBase,

  /// The merge stopped with conflicts and was undone. See
  /// [DeliveryUpdateService.updateFromBase] for why this is not left for the
  /// user to finish.
  conflicted,

  /// The conflicting merge could not even be undone. The rarest outcome and
  /// the only one that leaves the working tree changed, so it gets its own
  /// case rather than being folded into [conflicted]: the sentence the user
  /// reads has to tell them their tree is mid-merge.
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
/// **This is the app's own operation, not a prompt, and the reason is the whole
/// design of the delivery strip.** Every prompt in that strip names work whose
/// *content* a model has to invent — a commit message, the right side of a
/// conflict hunk, what a reviewer meant. "Merge `origin/main` into this branch"
/// has no content: it is one command with one argument, and the only way to get
/// it wrong is to run it at the wrong moment. Those moments are exactly what an
/// app can check and a prompt cannot be trusted to — an agent asked to update a
/// branch will cheerfully do it on top of uncommitted work, because it has no
/// standing rule that says not to.
///
/// **It fails closed, in four ways, and each of them is a refusal rather than a
/// best effort:**
///
/// * A live agent stops it. Same rule as `SessionArchiveService`, same reason:
///   rewriting the files a running agent is holding is not an update.
/// * Any uncommitted change stops it, even one git would have merged around.
///   Half of `git merge`'s behaviour with a dirty tree is "refuse" and the other
///   half is "silently succeed and blend the user's unrecorded edits into a
///   merge commit"; a button that does one or the other depending on which
///   files happen to be dirty is not a button anyone can learn.
/// * A conflicting merge is **aborted**, not left for the user. This is the one
///   worth arguing for, because leaving it is what git itself does. The strip
///   already has a better answer for a conflict — `Resolve conflicts` is a
///   prompt, and the agent is right there — and an app-owned button that ends
///   by dropping a half-merged index into the working tree has quietly handed
///   the user a job they did not ask for, in a state the strip cannot describe.
///   So it undoes its own mess and says so, and the next poll surfaces the
///   conflict through the action that was built for it.
/// * Anything else git says comes back as [UpdateOutcome.failed] carrying git's
///   own stderr, because a message from git beats a message we invented.
///
/// It never fetches. The base is whatever `origin/main` this clone last saw —
/// see `SessionDelivery.isBehindBase`, which is careful to treat that as
/// evidence in one direction only — and adding a network round trip behind a
/// button labelled `Update` would make a fast local operation intermittently
/// slow for a freshness the strip does not claim to have.
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

    // The same reading the strip drew its `Update` button from, rather than a
    // fresh set of git processes: the base it names is the base the "N behind"
    // fact was measured against, and re-deriving it here could merge a
    // different ref from the one the user was looking at.
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
      // as the last poll. This is the check that protects work nobody has
      // recorded, so it is worth one process to make it true *now*.
      if ((await changes.changes(directory)).isNotEmpty) {
        return const UpdateOutcome.refused(UpdateRefusal.uncommittedChanges);
      }
      await changes.mergeRef(directory, base);
    } catch (error) {
      // A merge that stopped leaves MERGE_HEAD behind whether it stopped for a
      // conflict or for something else, so the abort is attempted either way
      // and its answer is what tells the two apart: a successful abort means
      // there was a merge in progress to undo, which is what a conflict looks
      // like. An abort that fails on a repository with no merge in progress is
      // the ordinary case for every *other* failure, and falls through to the
      // error git actually reported.
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

  /// Whether the working tree still has a merge in progress.
  ///
  /// Asked only after an abort failed, to tell "there was nothing to abort"
  /// (an ordinary git failure) from "the abort itself could not clean up" (the
  /// one outcome that leaves the user's tree changed). `MERGE_HEAD` is the ref
  /// git creates when a merge stops and deletes when it finishes or is undone,
  /// so resolving it is the question. A probe that throws answers "no": this is
  /// only refining an error message that is already about to be shown, and a
  /// failed probe must not become a second failure.
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
