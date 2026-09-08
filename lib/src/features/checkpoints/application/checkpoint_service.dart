import '../../../core/process/command_runner_factory.dart';
import '../../../core/process/path_translator.dart';
import '../../../core/util/clock.dart';
import '../../environments/data/execution_environment_dao.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/execution_environment.dart';
import '../../git/data/git_files.dart';
import '../../git/data/git_service.dart';
import '../../git/data/hunk_patch.dart';
import '../../git/domain/file_change.dart';
import '../data/checkpoint_dao.dart';
import '../domain/checkpoint.dart';

/// **The half of an undo this app cannot do, said where the decision is made.**
///
/// A checkpoint is a git tree. We keep no cursor into any of the three CLIs'
/// conversations, so an agent whose edits have just been rolled back still
/// believes it made them and carries on from there — which is how a restore
/// quietly becomes a second way to lose work. It is structural, and that is
/// precisely why it has to be on screen rather than discovered afterwards.
const String kRestoreLeavesTheConversation =
    'Files only: the agent’s conversation is not rewound. It still believes it '
    'made these edits and will carry on from there, so tell it what you rolled '
    'back.';

/// Why restoring would be refused, or `null` when it would not.
///
/// **One function, and the write path asserts on it.**
/// [CheckpointService.restore] refuses on what this returns and the dialog
/// shows the same string verbatim, so the reason on screen and the rule that
/// was applied cannot drift apart. The MCP tool re-throws it for the same
/// reason.
String? checkpointRestoreRefusal({
  required bool treeMovedSinceLastCheckpoint,
  required int? safetySequence,
}) {
  if (!treeMovedSinceLastCheckpoint) return null;
  // A safety capture that returned null means the tree was already recorded,
  // so there is a checkpoint to come back to either way — never a number we
  // do not have.
  final saved = safetySequence == null
      ? 'Those changes are already checkpointed'
      : 'Those changes were saved as checkpoint $safetySequence';
  return 'The working tree has changed since the last checkpoint. $saved, so '
      'nothing is lost either way; confirm to restore anyway.\n\n'
      '$kRestoreLeavesTheConversation';
}

/// What a restore just did, in the vocabulary the refusal is written in.
///
/// [kRestoreLeavesTheConversation] again, because it is true of a restore that
/// nobody had to confirm as much as of one that was refused first. The one
/// case it is left off is the restore that wrote nothing: there is no rollback
/// to tell the agent about.
String restoreOutcomeMessage(RestoreOutcome outcome) {
  if (outcome.alreadyThere) {
    return 'The working tree already matched that checkpoint. Nothing changed.';
  }
  final count = outcome.files.length;
  final safety = outcome.safetyCheckpoint;
  final undo = safety == null
      ? ''
      : ' Undo it by restoring checkpoint ${safety.sequence}.';
  return 'Restored $count file${count == 1 ? '' : 's'}.$undo\n\n'
      '$kRestoreLeavesTheConversation';
}

/// Raised when a restore would throw away work the user has not seen recorded.
///
/// Carries what would be lost so the caller can say so before asking again with
/// `confirm`.
class CheckpointConflict implements Exception {
  CheckpointConflict(this.message, {this.safetyCheckpoint});
  final String message;

  /// The checkpoint taken of the *current* tree before the refusal. The work is
  /// therefore already safe, whatever the user decides.
  final Checkpoint? safetyCheckpoint;

  @override
  String toString() => 'CheckpointConflict: $message';
}

/// What a restore did.
class RestoreOutcome {
  const RestoreOutcome({
    required this.restored,
    required this.safetyCheckpoint,
    required this.files,
    required this.alreadyThere,
  });

  final Checkpoint restored;

  /// The checkpoint of the tree as it was a moment before, so the restore can
  /// itself be undone. `null` only when the tree already matched the most
  /// recent checkpoint, which is then the safety point.
  final Checkpoint? safetyCheckpoint;

  final List<FileChange> files;

  /// True when the working tree already was what was asked for. Nothing was
  /// applied, and that is a success, not a failure.
  final bool alreadyThere;
}

/// Capturing and restoring per-turn snapshots of a repository's working tree.
///
/// **How a checkpoint is made, and why this way.** `git stash create` was the
/// obvious candidate and is wrong: it silently ignores untracked files, and a
/// turn's new files are most of what an agent produces (`git stash create -u` is
/// not a thing — git parses the `-u` as the stash message, which is how that
/// mistake survives review). So a checkpoint is a `git write-tree` over a
/// **private index**: a directory inside the repository's own git directory
/// holding nothing but `commondir`, `HEAD` and an index of its own. A `git
/// add -A` scoped to that directory stages the whole working tree,
/// untracked files included, into an index the user does not own, and
/// `write-tree` turns it into a tree object in the repository's real object
/// store.
///
/// Nothing touches the user's index, `HEAD`, working tree, branches, stash or
/// remotes. The repository gains objects — which is what a snapshot *is* — and
/// one ref per session under `refs/karmashala/`, which keeps them from being
/// garbage collected and stays out of `git branch`, `git log` and `git status`.
class CheckpointService {
  CheckpointService({
    required this.runnerFactory,
    required this.environmentDao,
    required this.dao,
    required this.clock,
    required this.newId,
    this.files = const HostGitFiles(),
  });

  final CommandRunnerFactory runnerFactory;
  final ExecutionEnvironmentDao environmentDao;
  final CheckpointDao dao;
  final Clock clock;
  final String Function() newId;

  /// How the private index's directory and the scratch patch are written. A
  /// seam so a test can watch them without a disk; see [GitFiles].
  final GitFiles files;

  // --- capture ---------------------------------------------------------------

  /// Records what [repo] looks like now as a checkpoint of [sessionId].
  ///
  /// Returns `null` when the working tree is byte-for-byte what the previous
  /// checkpoint already holds — a turn that changed nothing is not a thing to
  /// undo, and a chain of identical trees makes the ones that matter harder to
  /// find.
  Future<Checkpoint?> capture(
    EnvironmentPath repo, {
    required String sessionId,
    CheckpointReason reason = CheckpointReason.turn,
    String? label,
    bool evenIfUnchanged = false,
  }) async {
    final git = _gitFor(repo);
    final dirs = await git.checkpointDirs(repo);
    await git.ensureCheckpointDirs(repo, dirs);
    final tree = await git.writeWorkingTree(repo, dirs);

    final previous = dao.latestFor(sessionId);
    if (!evenIfUnchanged && previous != null && previous.treeSha == tree) {
      return null;
    }

    final commit = await git.commitTree(
      repo,
      tree: tree,
      parent: previous?.commitSha,
      message: label ?? '${reason.name} checkpoint for session $sessionId',
    );
    await git.updateRef(repo, Checkpoint.refFor(sessionId), commit);

    final files = previous == null
        ? await _changesAgainstHead(git, repo, tree)
        : await git.diffNameStatus(repo, from: previous.treeSha, to: tree);

    return dao.insert(
      Checkpoint(
        id: newId(),
        sessionId: sessionId,
        repository: repo,
        // Replaced by the DAO, which owns the numbering.
        sequence: 0,
        treeSha: tree,
        commitSha: commit,
        parentCommitSha: previous?.commitSha,
        headSha: await git.revParse(repo, 'HEAD'),
        reason: reason,
        label: label,
        createdAt: clock.nowUtc(),
        files: files,
      ),
    );
  }

  /// The first checkpoint of a session has no predecessor, so "what changed" is
  /// measured against the commit the repository is on. In a repository with no
  /// commits, everything in the tree is new.
  Future<List<FileChange>> _changesAgainstHead(
    GitService git,
    EnvironmentPath repo,
    String tree,
  ) async {
    final head = await git.revParse(repo, 'HEAD');
    if (head == null) return const [];
    return git.diffNameStatus(repo, from: head, to: tree);
  }

  // --- reading ---------------------------------------------------------------

  List<Checkpoint> forSession(String sessionId) => dao.forSession(sessionId);

  List<Checkpoint> recent({int limit = 50}) => dao.recent(limit: limit);

  Checkpoint? byId(String id) => dao.getById(id);

  /// The diff this checkpoint *is*: what changed between the one before it and
  /// it. Empty for the first checkpoint of a session in a repository with no
  /// commits.
  Future<String> diffOf(Checkpoint checkpoint) async {
    // The previous checkpoint's tree if there is one; otherwise the commit the
    // repository was on, which is the only earlier state that exists.
    final base = _previousTreeOf(checkpoint) ?? checkpoint.headSha;
    if (base == null) return '';
    return _gitFor(
      checkpoint.repository,
    ).diffObjects(checkpoint.repository, from: base, to: checkpoint.treeSha);
  }

  /// What has changed in [repo] since [sessionId]'s most recent checkpoint.
  Future<String> pendingSince(EnvironmentPath repo, String sessionId) async {
    final latest = dao.latestFor(sessionId);
    if (latest == null) return '';
    return _gitFor(repo).diffObjects(repo, from: latest.treeSha);
  }

  // --- restore ---------------------------------------------------------------

  /// Puts [repo]'s working tree back to what [checkpoint] holds.
  ///
  /// Two protections, both deliberate:
  ///
  /// * A **safety checkpoint** of the tree as it is right now is recorded first,
  ///   whenever the tree has moved since the last checkpoint. Undo is therefore
  ///   itself undoable, which is the difference between a recovery feature and a
  ///   second way to lose work.
  /// * If the tree has moved since the latest checkpoint — the agent, or the
  ///   user, has been working since — the restore is **refused** unless
  ///   [confirm] is set. The safety checkpoint is still taken before the
  ///   refusal, so nothing is riding on the user answering correctly.
  ///
  /// The index is not touched. Whatever the user had staged stays staged; only
  /// the working tree moves.
  Future<RestoreOutcome> restore(
    Checkpoint checkpoint, {
    bool confirm = false,
    List<HunkSelection> selection = const [],
  }) async {
    final repo = checkpoint.repository;
    final git = _gitFor(repo);
    final dirs = await git.checkpointDirs(repo);
    await git.ensureCheckpointDirs(repo, dirs);

    final current = await git.writeWorkingTree(repo, dirs);
    final latest = dao.latestFor(checkpoint.sessionId);
    final movedSinceLastCheckpoint =
        latest != null && latest.treeSha != current;

    Checkpoint? safety;
    if (movedSinceLastCheckpoint) {
      safety = await capture(
        repo,
        sessionId: checkpoint.sessionId,
        reason: CheckpointReason.safety,
        label: 'before restoring checkpoint ${checkpoint.sequence}',
      );
    }

    final refusal = checkpointRestoreRefusal(
      treeMovedSinceLastCheckpoint: movedSinceLastCheckpoint,
      safetySequence: safety?.sequence,
    );
    if (refusal != null && !confirm) {
      throw CheckpointConflict(refusal, safetyCheckpoint: safety);
    }

    if (current == checkpoint.treeSha && selection.isEmpty) {
      return RestoreOutcome(
        restored: checkpoint,
        safetyCheckpoint: safety,
        files: const [],
        alreadyThere: true,
      );
    }

    final patch = await git.diffObjects(
      repo,
      from: checkpoint.treeSha,
      to: current,
    );
    final wanted = selection.isEmpty
        ? patch
        : buildPatch(splitUnifiedDiff(patch), selection);
    if (wanted.trim().isEmpty) {
      return RestoreOutcome(
        restored: checkpoint,
        safetyCheckpoint: safety,
        files: const [],
        alreadyThere: true,
      );
    }

    // The patch describes checkpoint -> now, so applying it backwards is what
    // turns now into the checkpoint. Reversing git's own diff is what makes a
    // file that appeared since disappear again, and one that was deleted come
    // back, without this code ever writing to the working tree itself.
    await git.applyPatch(repo, dirs, wanted, reverse: true);

    final files = await git.diffNameStatus(
      repo,
      from: checkpoint.treeSha,
      to: current,
    );
    return RestoreOutcome(
      restored: checkpoint,
      safetyCheckpoint: safety,
      files: files,
      alreadyThere: false,
    );
  }

  // --- hunk operations on the current diff -----------------------------------

  /// The unstaged diff of [repo], split into files and hunks.
  Future<List<FilePatch>> unstagedHunks(EnvironmentPath repo) async =>
      splitUnifiedDiff(await _gitFor(repo).diff(repo));

  /// The staged diff of [repo], split into files and hunks.
  Future<List<FilePatch>> stagedHunks(EnvironmentPath repo) async =>
      splitUnifiedDiff(await _gitFor(repo).diff(repo, staged: true));

  /// Stages [selection] out of the unstaged diff.
  Future<void> stage(
    EnvironmentPath repo,
    List<HunkSelection> selection,
  ) async {
    final git = _gitFor(repo);
    final patch = buildPatch(splitUnifiedDiff(await git.diff(repo)), selection);
    if (patch.trim().isEmpty) return;
    await git.applyPatch(
      repo,
      await git.checkpointDirs(repo),
      patch,
      cached: true,
    );
  }

  /// Unstages [selection] out of the staged diff.
  Future<void> unstage(
    EnvironmentPath repo,
    List<HunkSelection> selection,
  ) async {
    final git = _gitFor(repo);
    final patch = buildPatch(
      splitUnifiedDiff(await git.diff(repo, staged: true)),
      selection,
    );
    if (patch.trim().isEmpty) return;
    await git.applyPatch(
      repo,
      await git.checkpointDirs(repo),
      patch,
      cached: true,
      reverse: true,
    );
  }

  /// Throws [selection] away from the working tree.
  ///
  /// Takes a checkpoint first when [sessionId] is given, because reverting a
  /// hunk destroys work exactly as thoroughly as restoring does.
  Future<void> revert(
    EnvironmentPath repo,
    List<HunkSelection> selection, {
    String? sessionId,
  }) async {
    final git = _gitFor(repo);
    final patch = buildPatch(splitUnifiedDiff(await git.diff(repo)), selection);
    if (patch.trim().isEmpty) return;
    if (sessionId != null) {
      await capture(
        repo,
        sessionId: sessionId,
        reason: CheckpointReason.safety,
        label: 'before reverting hunks',
      );
    }
    await git.applyPatch(
      repo,
      await git.checkpointDirs(repo),
      patch,
      reverse: true,
    );
  }

  // --- internals -------------------------------------------------------------

  String? _previousTreeOf(Checkpoint checkpoint) {
    if (checkpoint.sequence <= 1) return null;
    final all = dao.forSession(checkpoint.sessionId);
    for (final other in all) {
      if (other.sequence == checkpoint.sequence - 1) return other.treeSha;
    }
    return null;
  }

  GitService _gitFor(EnvironmentPath repo) {
    final env = environmentDao.getById(repo.environmentId);
    if (env == null) {
      throw GitException('Unknown environment: ${repo.environmentId}');
    }
    return GitService(
      runnerFactory.forEnvironment(env),
      files: files,
      hostPathOf: _hostPathFor(env),
    );
  }

  /// How a path inside [env] is spelled for this process.
  ///
  /// Only two things are ever opened directly: the private index's directory
  /// and the scratch patch, both inside the repository's git directory. A
  /// remote repository has neither within reach, so SSH fails with a sentence
  /// rather than a `FileSystemException` from three layers down.
  HostPathOf _hostPathFor(ExecutionEnvironment env) => switch (env.kind) {
    // Already this process's own filesystem, whichever local OS it is.
    EnvironmentKind.windowsNative ||
    EnvironmentKind.localPosix => sameEnvironmentPath,
    EnvironmentKind.wsl =>
      (path) => const PathTranslator()
          .translate(
            EnvironmentPath(environmentId: env.id, path: path),
            from: env,
            to: ExecutionEnvironment(
              id: 'windows',
              kind: EnvironmentKind.windowsNative,
              name: 'Windows',
              createdAt: DateTime.utc(2020),
            ),
          )
          .path,
    EnvironmentKind.ssh => (_) => throw GitException(
      'Checkpoints are not supported for repositories on ${env.name}: they '
      'need a private git index this machine can write to.',
    ),
  };
}
