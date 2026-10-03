import 'package:agent_cli/process.dart';
import 'package:path/path.dart' as p;
import 'package:karmashala_core/util.dart';
import 'package:karmashala_git/git.dart';
import '../domain/checkpoint.dart';
import '../domain/checkpoint_rules.dart';
import 'checkpoint_records.dart';

/// **The half of an undo this app cannot do.** A checkpoint is a git tree; we
/// keep no cursor into any CLI's conversation, so the agent carries on.
const String kRestoreLeavesTheConversation =
    'Files only: the agent’s conversation is not rewound. It still believes it '
    'made these edits and will carry on from there, so tell it what you rolled '
    'back.';

/// Why restoring would be refused, or `null`. One function: [restore] refuses
/// on what this returns and the dialog shows the same string verbatim.
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

/// What a restore just did, in the vocabulary the refusal is written in —
/// left off only for the restore that wrote nothing.
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
/// Carries what would be lost, so the caller can say so before asking again.
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
/// A `git write-tree` over a **private index**, so nothing the user owns moves.
class CheckpointService {
  CheckpointService({
    required this.runnerFactory,
    required this.environmentOf,
    required this.records,
    required this.clock,
    required this.newId,
    this.files = const HostGitFiles(),
  });

  final CommandRunnerFactory runnerFactory;

  /// The environment row an id names, or null when there is none.
  final ExecutionEnvironment? Function(String id) environmentOf;
  final CheckpointRecords records;
  final Clock clock;
  final String Function() newId;

  /// How the private index's directory and the scratch patch are written. A
  /// seam so a test can watch them without a disk; see [GitFiles].
  final GitFiles files;

  // --- capture ---------------------------------------------------------------

  /// Records what [repo] looks like now as a checkpoint of [sessionId]. `null`
  /// when the tree is byte-for-byte the previous checkpoint.
  Future<Checkpoint?> capture(
    EnvironmentPath repo, {
    required String sessionId,
    CheckpointReason reason = CheckpointReason.turn,
    String? label,
    bool evenIfUnchanged = false,
    int? turn,
    String? prompt,
  }) async => recordTree(
    repo,
    await snapshot(repo),
    sessionId: sessionId,
    reason: reason,
    label: label,
    evenIfUnchanged: evenIfUnchanged,
    turn: turn,
    prompt: prompt,
  );

  /// Where each repository's private index lives, as git named it. Asked once
  /// per repository: two `rev-parse` calls on every snapshot were a quarter of
  /// the time an agent's first tool is held for it (~30 ms a call on Windows).
  final Map<String, CheckpointGitDirs> _dirs = {};

  /// **The half of a capture that has to happen before a tool runs**: what
  /// [repo]'s working tree is now, written as a tree object. Answers its sha;
  /// [recordTree] makes it a checkpoint, and can wait.
  Future<String> snapshot(EnvironmentPath repo) async {
    final git = _gitFor(repo);
    final key = '${repo.environmentId}\u0000${repo.path}';
    final dirs = _dirs[key] ??= await git.checkpointDirs(repo);
    return _exclusive(repo, () async {
      await git.ensureCheckpointDirs(repo, dirs);
      return git.writeWorkingTree(repo, dirs);
    });
  }

  final Map<String, Future<void>> _indexUsers = {};

  /// Runs [work] alone on [repo]'s private index and scratch patch. Sessions
  /// share a checkout, and git refuses a second writer of one index outright.
  Future<T> _exclusive<T>(EnvironmentPath repo, Future<T> Function() work) {
    final key = '${repo.environmentId}\u0000${repo.path}';
    final result = (_indexUsers[key] ?? Future<void>.value()).then(
      (_) => work(),
    );
    final tail = result.then<void>((_) {}, onError: (Object _) {});
    _indexUsers[key] = tail;
    tail.whenComplete(() {
      if (identical(_indexUsers[key], tail)) _indexUsers.remove(key);
    });
    return result;
  }

  /// Records [tree], a [snapshot] of [repo], as a checkpoint of [sessionId]:
  /// the commit, the ref that keeps it, and what changed. `null` when the tree
  /// is byte-for-byte the previous checkpoint.
  Future<Checkpoint?> recordTree(
    EnvironmentPath repo,
    String tree, {
    required String sessionId,
    CheckpointReason reason = CheckpointReason.turn,
    String? label,
    bool evenIfUnchanged = false,
    int? turn,
    String? prompt,
  }) async {
    final git = _gitFor(repo);
    final previous = latestCheckpointIn(
      await records.forSession(sessionId),
      repository: repo,
    );
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

    final head = await git.revParse(repo, 'HEAD');
    // The first checkpoint of a tree has no predecessor, so what changed is
    // measured against the commit the repository is on; with none, nothing is.
    final base = previous?.treeSha ?? head;
    final files = base == null
        ? const <FileChange>[]
        : await git.diffNameStatus(repo, from: base, to: tree);
    final lineStats = base == null || files.isEmpty
        ? const <String, FileDiffStat>{}
        : await git.diffNumstat(repo, from: base, to: tree);

    return records.record(
      Checkpoint(
        id: newId(),
        sessionId: sessionId,
        repository: repo,
        // Replaced by the store, which owns the numbering.
        sequence: 0,
        treeSha: tree,
        commitSha: commit,
        parentCommitSha: previous?.commitSha,
        headSha: head,
        reason: reason,
        label: label,
        createdAt: clock.nowUtc(),
        files: files,
        turn: turn,
        prompt: prompt,
        lineStats: lineStats,
      ),
    );
  }

  /// Keeps the newest [keep] checkpoints of [repo] for [sessionId]. The chain
  /// is re-committed over the kept trees so the dropped ones stop being
  /// reachable and git can collect them. Returns how many were dropped.
  Future<int> prune(
    EnvironmentPath repo, {
    required String sessionId,
    required int keep,
  }) async {
    final chain = checkpointChainIn(await records.forSession(sessionId), repo);
    if (keep <= 0 || chain.length <= keep) return 0;
    final dropped = chain.sublist(0, chain.length - keep);
    final kept = chain.sublist(chain.length - keep);
    final git = _gitFor(repo);
    final rewritten = <String, ({String commit, String? parent})>{};
    String? parent;
    for (final checkpoint in kept) {
      final commit = await git.commitTree(
        repo,
        tree: checkpoint.treeSha,
        parent: parent,
        message:
            checkpoint.label ??
            '${checkpoint.reason.name} checkpoint for session $sessionId',
      );
      rewritten[checkpoint.id] = (commit: commit, parent: parent);
      parent = commit;
    }
    await git.updateRef(repo, Checkpoint.refFor(sessionId), parent!);
    await records.prune(
      sessionId,
      dropIds: [for (final c in dropped) c.id],
      rewritten: rewritten,
    );
    return dropped.length;
  }

  /// Why [repo] cannot be checkpointed from here, or `null` when it can.
  String? unsupportedReason(EnvironmentPath repo) {
    final env = environmentOf(repo.environmentId);
    if (env == null) return 'its environment ${repo.environmentId} is unknown';
    if (env.kind == EnvironmentKind.ssh) {
      return 'checkpoints are not supported for repositories on ${env.name}: '
          'they need a private git index this machine can write to';
    }
    return null;
  }

  /// Directories git has named the work-tree root of. Only answers are kept: a
  /// path that is in no repository now may be a worktree a moment later.
  final Map<String, String> _roots = {};

  /// The repository [path] is in — a file, or a directory — as this environment
  /// spells paths, or `null`. Walks up past paths that do not exist yet.
  Future<EnvironmentPath?> repositoryRootOf(EnvironmentPath path) async {
    final env = environmentOf(path.environmentId);
    if (env == null || env.kind == EnvironmentKind.ssh) return null;
    final context = usesWindowsPaths(env.kind) ? p.windows : p.posix;
    final git = _gitFor(path);
    var probe = context.normalize(path.path);
    for (var depth = 0; depth < 8; depth++) {
      final key = '${path.environmentId}\u0000$probe';
      var root = _roots[key];
      if (root == null) {
        final answer = await git.topLevel(
          EnvironmentPath(environmentId: path.environmentId, path: probe),
        );
        // git answers with forward slashes on Windows; stored paths use the
        // environment's own, or one repository becomes two chains.
        if (answer != null) root = _roots[key] = context.normalize(answer);
      }
      if (root != null) {
        return EnvironmentPath(environmentId: path.environmentId, path: root);
      }
      final parent = context.dirname(probe);
      if (parent == probe) break;
      probe = parent;
    }
    return null;
  }

  // --- reading ---------------------------------------------------------------

  Future<List<Checkpoint>> forSession(String sessionId) =>
      records.forSession(sessionId);

  Future<Checkpoint?> byId(String id) => records.byId(id);

  /// The diff this checkpoint *is*: what changed between the one before it and
  /// it. Empty for the first checkpoint of a session in a repository with no
  /// commits.
  Future<String> diffOf(Checkpoint checkpoint) async {
    // The previous checkpoint's tree if there is one; otherwise the commit the
    // repository was on, which is the only earlier state that exists.
    final base =
        previousCheckpointIn(
          await records.forSession(checkpoint.sessionId),
          checkpoint,
        )?.treeSha ??
        checkpoint.headSha;
    if (base == null) return '';
    return _gitFor(
      checkpoint.repository,
    ).diffObjects(checkpoint.repository, from: base, to: checkpoint.treeSha);
  }

  /// What has changed in [repo] since [sessionId]'s most recent checkpoint.
  Future<String> pendingSince(EnvironmentPath repo, String sessionId) async {
    final latest = latestCheckpointIn(
      await records.forSession(sessionId),
      repository: repo,
    );
    if (latest == null) return '';
    return _gitFor(repo).diffObjects(repo, from: latest.treeSha);
  }

  // --- restore ---------------------------------------------------------------

  /// Puts [repo]'s working tree back to what [checkpoint] holds. A safety
  /// checkpoint is taken first, and a moved tree is refused without [confirm].
  Future<RestoreOutcome> restore(
    Checkpoint checkpoint, {
    bool confirm = false,
    List<HunkSelection> selection = const [],
  }) async {
    final repo = checkpoint.repository;
    final git = _gitFor(repo);
    final dirs = await git.checkpointDirs(repo);
    final current = await _exclusive(repo, () async {
      await git.ensureCheckpointDirs(repo, dirs);
      return git.writeWorkingTree(repo, dirs);
    });
    final latest = latestCheckpointIn(
      await records.forSession(checkpoint.sessionId),
      repository: checkpoint.repository,
    );
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

    // The patch describes checkpoint -> now, so applying it backwards turns now
    // into the checkpoint, without this code writing to the working tree itself.
    await _exclusive(
      repo,
      () => git.applyPatch(repo, dirs, wanted, reverse: true),
    );

    final changed = await git.diffNameStatus(
      repo,
      from: checkpoint.treeSha,
      to: current,
    );
    // What was *written*, not what differs: a per-path restore applied only the
    // paths it was given, and naming every file that moved would overstate it.
    final restoredPaths = {for (final choice in selection) choice.path};
    return RestoreOutcome(
      restored: checkpoint,
      safetyCheckpoint: safety,
      files: restoredPaths.isEmpty
          ? changed
          : [
              for (final file in changed)
                if (restoredPaths.contains(file.path)) file,
            ],
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
    final dirs = await git.checkpointDirs(repo);
    await _exclusive(
      repo,
      () => git.applyPatch(repo, dirs, patch, cached: true),
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
    final dirs = await git.checkpointDirs(repo);
    await _exclusive(
      repo,
      () => git.applyPatch(repo, dirs, patch, cached: true, reverse: true),
    );
  }

  /// Throws [selection] away from the working tree, taking a checkpoint first
  /// when [sessionId] is given — reverting a hunk destroys work just as well.
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
    final dirs = await git.checkpointDirs(repo);
    await _exclusive(
      repo,
      () => git.applyPatch(repo, dirs, patch, reverse: true),
    );
  }

  // --- internals -------------------------------------------------------------

  GitService _gitFor(EnvironmentPath repo) {
    final env = environmentOf(repo.environmentId);
    if (env == null) {
      throw GitException('Unknown environment: ${repo.environmentId}');
    }
    return GitService(
      runnerFactory.forEnvironment(env),
      files: files,
      hostPathOf: _hostPathFor(env),
    );
  }

  /// How a path inside [env] is spelled for this process. A remote repository
  /// has neither file within reach, so SSH fails with a sentence.
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
