import 'package:riverpod/riverpod.dart';

import '../../checkpoints/application/checkpoint_providers.dart';
import '../../checkpoints/application/checkpoint_service.dart';
import '../../checkpoints/data/checkpoint_dao.dart';
import '../../git/application/changes_providers.dart';
import 'package:karmashala_git/git.dart';
import '../../repositories/application/repository_providers.dart';
import '../domain/automation_run.dart';
import '../domain/undo_run.dart';
import 'automation_providers.dart';

/// Taking back what an unattended run did: files always, commits only when
/// [undoCommitsRefusal] allows — the tooltip and the write path read it alike.
class AutomationUndo {
  const AutomationUndo(this._ref);

  final Ref _ref;

  /// What [run] left on the branch, measured now. A reading that could not be
  /// taken is `null`, never zero: `published` is as fresh as the last fetch.
  Future<RunCommits> commitsOf(AutomationRun run) async {
    final automation = _ref
        .read(automationDaoProvider)
        .getById(run.automationId);
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
      // column existed: a tree to restore and no commit to reset to.
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
      // The base is not in the first 200 commits: the history moved under us,
      // so there is no commit to reset back to.
      return RunCommits(baseSha: null, commits: made, published: 0);
    }

    var published = 0;
    var everAsked = false;
    for (final commit in made) {
      final remotes = await changes.remoteBranchesContaining(
        repository.path,
        commit.sha,
      );
      if (remotes == null) {
        return RunCommits(baseSha: baseSha, commits: made, published: null);
      }
      everAsked = true;
      if (remotes.isNotEmpty) published++;
    }
    return RunCommits(
      baseSha: baseSha,
      commits: made,
      published: made.isEmpty || everAsked ? published : null,
    );
  }

  /// Puts the files back as they stood before [run] started. A moved tree is
  /// refused once with a [CheckpointConflict] — `CheckpointService`'s own rule.
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
    return _ref.read(checkpointServiceProvider).restore(base, confirm: confirm);
  }

  /// Whether the commits may be dropped, in the tooltip's words; null means yes.
  String? commitsRefusal(RunCommits summary) => undoCommitsRefusal(summary);

  /// Drops the commits [run] made by moving the branch back to its base, and
  /// throws [undoCommitsRefusal] so a caller cannot get past the tooltip.
  Future<void> dropCommits(AutomationRun run, RunCommits summary) async {
    final refusal = undoCommitsRefusal(summary);
    if (refusal != null) throw StateError(refusal);

    final automation = _ref
        .read(automationDaoProvider)
        .getById(run.automationId);
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
