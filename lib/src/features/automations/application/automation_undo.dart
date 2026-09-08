import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../checkpoints/application/checkpoint_providers.dart';
import '../../checkpoints/application/checkpoint_service.dart';
import '../../checkpoints/data/checkpoint_dao.dart';
import '../../git/application/changes_providers.dart';
import '../../git/domain/git_commit.dart';
import '../../repositories/application/repository_providers.dart';
import '../domain/automation_run.dart';
import '../domain/undo_run.dart';
import 'automation_providers.dart';

/// Taking back what an unattended run did.
///
/// **Asymmetric, and the asymmetry is the design.** Restoring the files is
/// always offered — the base checkpoint holds the tree as it stood before the
/// agent touched it, and putting it back changes nothing outside this machine.
/// Dropping the commits is a history rewrite, so it is opt-in and refused once
/// any of them exists on a remote. The tooltip and this write path both read
/// [undoCommitsRefusal], so the reason on hover is the reason arming the drop
/// would throw.
class AutomationUndo {
  const AutomationUndo(this._ref);

  final Ref _ref;

  /// What [run] left on the branch, measured now.
  ///
  /// **A reading that could not be taken is `null`, never zero.** `published`
  /// reads remote-tracking refs, which are only as fresh as the last fetch, so
  /// an empty answer for a branch that really was pushed is possible — and that
  /// is the safe direction, because the caller refuses and says to fetch.
  Future<RunCommits> commitsOf(AutomationRun run) async {
    final automation = _ref.read(automationDaoProvider).getById(run.automationId);
    if (automation == null) return RunCommits.unread;
    final repository = _ref
        .read(repositoryDaoProvider)
        .getById(automation.repositoryId);
    final checkpointId = run.baseCheckpointId;
    if (repository == null || checkpointId == null) return RunCommits.unread;
    final base = _ref.read(checkpointDaoProvider).getById(checkpointId);
    final baseSha = base?.headSha;
    if (baseSha == null || baseSha.isEmpty) {
      // A repository with no commits yet, or a checkpoint from before the
      // column existed. There is a tree to restore and no commit to reset to.
      return const RunCommits(baseSha: null, commits: [], published: 0);
    }

    final changes = _ref.read(changesServiceProvider);
    List<GitCommit> log;
    try {
      log = await changes.log(repository.path, limit: 200);
    } on Object {
      return RunCommits.unread;
    }
    final made = <RunCommit>[];
    for (final commit in log) {
      if (commit.sha == baseSha) break;
      made.add(RunCommit(sha: commit.sha, subject: commit.subject));
    }
    if (made.length == log.length) {
      // The base is not in the first 200 commits: the history has moved under
      // us (a rebase), so there is no commit to reset back to.
      return RunCommits(baseSha: null, commits: made, published: 0);
    }

    var published = 0;
    var everAsked = false;
    for (final commit in made) {
      final remotes = await changes.remoteBranchesContaining(
        repository.path,
        commit.sha,
      );
      if (remotes == null) return RunCommits(baseSha: baseSha, commits: made, published: null);
      everAsked = true;
      if (remotes.isNotEmpty) published++;
    }
    return RunCommits(
      baseSha: baseSha,
      commits: made,
      published: made.isEmpty || everAsked ? published : null,
    );
  }

  /// Puts the files back as they stood before [run] started.
  ///
  /// Always offered. A tree that has moved since is refused **once** with a
  /// [CheckpointConflict] whose safety checkpoint already holds that work, and
  /// the caller confirms; that is `CheckpointService`'s own rule and this does
  /// not invent a second one.
  Future<RestoreOutcome> restoreFiles(
    AutomationRun run, {
    bool confirm = false,
  }) async {
    final checkpointId = run.baseCheckpointId;
    if (checkpointId == null) {
      throw StateError(
        'This run recorded no base, so there is nothing to put the files back '
        'to. Nothing is restored on a reading Karmashala never took.',
      );
    }
    final base = _ref.read(checkpointDaoProvider).getById(checkpointId);
    if (base == null) {
      throw StateError(
        'The checkpoint this run was taken against is gone, so there is '
        'nothing to put the files back to.',
      );
    }
    return _ref
        .read(checkpointServiceProvider)
        .restore(base, confirm: confirm);
  }

  /// Whether the commits may be dropped, in the words the button's tooltip
  /// shows. Null means they may.
  String? commitsRefusal(RunCommits summary) => undoCommitsRefusal(summary);

  /// Drops the commits [run] made, by moving the branch back to its base.
  ///
  /// **Asserts the same rule the checkbox's tooltip shows.** The refusal is
  /// thrown, in [undoCommitsRefusal]'s own words, so a caller that skipped the
  /// tooltip cannot get past it — that is the whole reason the rule is a
  /// function and not two sentences.
  ///
  /// The working tree is not touched: [restoreFiles] has already put it back,
  /// and this closes the gap where the files read as "put back" while
  /// `git log` still shows the agent's work.
  Future<void> dropCommits(AutomationRun run, RunCommits summary) async {
    final refusal = undoCommitsRefusal(summary);
    if (refusal != null) throw StateError(refusal);

    final automation = _ref.read(automationDaoProvider).getById(run.automationId);
    final repository = automation == null
        ? null
        : _ref.read(repositoryDaoProvider).getById(automation.repositoryId);
    if (repository == null) {
      throw StateError(
        'This run\'s checkout is no longer in the workspace, so nothing is '
        'moved.',
      );
    }
    final changes = _ref.read(changesServiceProvider);
    final branch = await changes.currentBranch(repository.path);
    if (branch == null || branch.isEmpty) {
      throw StateError(
        'The checkout is not on a branch, so there is no branch pointer to '
        'move back. Nothing is dropped on a reading Karmashala could not take.',
      );
    }
    await changes.moveBranchTo(
      repository.path,
      branch: branch,
      sha: summary.baseSha!,
    );
    _ref.read(automationsRevisionProvider.notifier).bump();
  }
}

final automationUndoProvider = Provider<AutomationUndo>(AutomationUndo.new);
