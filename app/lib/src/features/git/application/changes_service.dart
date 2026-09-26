import 'package:agent_cli/process.dart';
import '../../environments/application/environment_resolver.dart';
import '../../environments/data/execution_environment_dao.dart';
import 'package:karmashala_git/git.dart';

/// Notified with a repository whose working tree this service has just
/// rewritten, so Quick Open's index can mark that root stale.
typedef WorkingTreeChanged = void Function(EnvironmentPath repo);

/// A repository's changes and diffs; reads run where the files live, writes on
/// the row's runner. Almost read-only: committing and pushing are the agent's.
class ChangesService {
  ChangesService({
    required this.runnerFactory,
    required this.environmentDao,
    this.onWorkingTreeChanged,
    this.files = const HostGitFiles(),
  });

  final CommandRunnerFactory runnerFactory;
  final ExecutionEnvironmentDao environmentDao;

  /// The filesystem [originFacts] reads `.git` through. A seam so a test can
  /// count the reads without a disk; see [GitFiles].
  final GitFiles files;

  /// See [WorkingTreeChanged]. Null in a test that only asserts git arguments.
  final WorkingTreeChanged? onWorkingTreeChanged;

  ExecutionEnvironment _environmentOf(EnvironmentPath repo) {
    final resolved = ExecutionEnvironmentResolver(
      environments: environmentDao,
      runners: runnerFactory,
    ).resolveFor(repo);
    final env = resolved.environment;
    if (env == null) throw GitException(resolved.reason);
    return env;
  }

  /// Runs a read-only question on the runner that owns [repo]'s files, not the
  /// row's; returns no [EnvironmentPath], so a moved read cannot mis-spell one.
  Future<T> _ask<T>(
    EnvironmentPath repo,
    Future<T> Function(GitService git, EnvironmentPath at) question,
  ) {
    final target = gitProbeTargetFor(
      repo,
      _environmentOf(repo),
      windowsHost: () => environmentDao.getById(localHostEnvironmentId),
    );
    return question(
      GitService(runnerFactory.forEnvironment(target.environment)),
      target.path,
    );
  }

  GitService _gitFor(EnvironmentPath repo) =>
      GitService(runnerFactory.forEnvironment(_environmentOf(repo)));

  /// Changed files in [repo].
  Future<List<FileChange>> changes(EnvironmentPath repo) =>
      _ask(repo, (git, at) => git.status(at));

  /// The branch, its upstream, their divergence and the changed files, in one
  /// process. What a delivery row reads.
  Future<WorkingTreeStatus> statusWithBranch(EnvironmentPath repo) =>
      _ask(repo, (git, at) => git.statusWithBranch(at));

  /// The default branch this clone recorded for `origin`, or `null`.
  Future<String?> originHead(EnvironmentPath repo) =>
      _ask(repo, (git, at) => git.originHead(at));

  /// Both of [repo]'s `origin` facts — the URL and the default branch — from two
  /// file reads rather than two subprocesses, falling back to git per *fact* on
  /// any uncertainty at all: a wrong answer here is worse than a slow one.
  Future<RepositoryOrigin> originFacts(EnvironmentPath repo) async {
    final reading = await GitOriginReader(
      files: files,
      hostPathOf: hostPathMapperFor(_environmentOf(repo)),
    ).read(repo.path);

    // `_ask` only where a fact is missing, so a repository whose files
    // answered never builds a runner it has nothing to run.
    final url = reading.url.known
        ? reading.url.value
        : await _ask(repo, (git, at) => git.remoteUrl(at));
    if (url == null) return RepositoryOrigin.none;
    return RepositoryOrigin(
      url: url,
      head: reading.head.known
          ? reading.head.value
          : await _ask(repo, (git, at) => git.originHead(at)),
    );
  }

  /// Whether a merge is half-done in [repo], from one `.git` stat rather than a
  /// process; null when this host cannot see that filesystem.
  Future<bool?> mergeInProgress(EnvironmentPath repo) => GitMergeStateReader(
    files: files,
    hostPathOf: hostPathMapperFor(_environmentOf(repo)),
  ).read(repo.path);

  /// Which family of worktrees [repo] belongs to, or null — which means "ask
  /// the way you used to", never "a family of one". Callers group by it so one
  /// `git worktree list` answers for the whole family instead of one per row.
  Future<String?> familyKey(EnvironmentPath repo) => GitOriginReader(
    files: files,
    hostPathOf: hostPathMapperFor(_environmentOf(repo)),
  ).commonDirectory(repo.path);

  /// The current branch of [repo], or `null` if detached/unknown.
  Future<String?> currentBranch(EnvironmentPath repo) =>
      _ask(repo, (git, at) => git.currentBranch(at));

  /// The `origin` remote URL of [repo], or `null` if there is none.
  Future<String?> remoteUrl(EnvironmentPath repo) =>
      _ask(repo, (git, at) => git.remoteUrl(at));

  /// Commits on [repo]'s current branch that [base] does not have; `null` when
  /// git could not answer.
  Future<int?> commitsAhead(EnvironmentPath repo, {required String base}) =>
      _ask(repo, (git, at) => git.commitsAhead(at, base: base));

  /// Lines added and removed in [repo], against [base] when one is given.
  Future<DiffStat?> diffStat(EnvironmentPath repo, {String? base}) =>
      _ask(repo, (git, at) => git.diffStat(at, base: base));

  /// Lines added and removed per file in [repo]. Empty when git could not say,
  /// and a path git never mentioned — an untracked one — is simply absent.
  Future<Map<String, FileDiffStat>> fileDiffStats(EnvironmentPath repo) =>
      _ask(repo, (git, at) => git.fileDiffStats(at));

  /// How [repo] stands against [base] in both directions; `null` when git could
  /// not answer.
  Future<AheadBehind?> aheadBehind(
    EnvironmentPath repo, {
    required String base,
  }) => _ask(repo, (git, at) => git.aheadBehind(at, base: base));

  /// Resolves [rev] in [repo], or `null` when it names nothing. Asking for
  /// `refs/heads/<name>` is how "does this branch exist" is asked.
  Future<String?> revParse(EnvironmentPath repo, String rev) =>
      _ask(repo, (git, at) => git.revParse(at, rev));

  /// The remote-tracking branches holding [rev]; `null` when git could not
  /// answer, empty when nothing outside this machine has those commits.
  Future<List<String>?> remoteBranchesContaining(
    EnvironmentPath repo,
    String rev,
  ) => _ask(repo, (git, at) => git.remoteBranchesContaining(at, rev));

  /// The upstream of [branch] in [repo] (`origin/work`), or `null`.
  Future<String?> upstreamOf(EnvironmentPath repo, String branch) =>
      _ask(repo, (git, at) => git.upstreamOf(at, branch));

  /// Unified diff for [repo], optionally limited to [path] / staged changes.
  /// [base] is the ref it is taken against — `HEAD` for staged and unstaged
  /// together, which is what [fileDiffStats] counts.
  Future<String> diff(
    EnvironmentPath repo, {
    String? path,
    bool staged = false,
    String? base,
  }) => _ask(
    repo,
    (git, at) => git.diff(at, path: path, staged: staged, base: base),
  );

  /// Unified diff for an untracked [path] — the all-added file plain
  /// `git diff` cannot produce, because it never reports untracked paths.
  Future<String> diffUntracked(EnvironmentPath repo, String path) =>
      _ask(repo, (git, at) => git.diffUntracked(at, path));

  /// Whether git tracks [path] in [repo].
  Future<bool> isTracked(EnvironmentPath repo, String path) =>
      _ask(repo, (git, at) => git.isTracked(at, path));

  /// The diff for one file, asking whichever question git will answer for it.
  ///
  /// A plain `git diff` reports nothing for an untracked path, which is what
  /// used to render as an empty pane. The second question is only worth asking
  /// when the first came back empty **and** git confirms the path is untracked:
  /// a tracked file with no changes is also empty, and `--no-index` would draw
  /// the whole of it as added.
  Future<String> diffForFile(
    EnvironmentPath repo,
    String path, {
    String? base,
  }) async {
    final patch = await diff(repo, path: path, base: base);
    if (patch.isNotEmpty) return patch;
    if (await isTracked(repo, path)) return patch;
    return diffUntracked(repo, path);
  }

  /// The content fingerprint of each of [paths] as they stand on disk, for the
  /// review-thread anchors. A path git could not hash is absent from the map,
  /// which the caller must read as "cannot tell" and never as unchanged.
  Future<Map<String, String>> blobShas(
    EnvironmentPath repo,
    List<String> paths,
  ) => _ask(repo, (git, at) => git.hashObjects(at, paths));

  /// Recent commits for [repo].
  Future<List<GitCommit>> log(EnvironmentPath repo, {int limit = 20}) =>
      _ask(repo, (git, at) => git.log(at, limit: limit));

  /// Merges [branch] into [repo]'s checked-out branch. `touch` rather than
  /// `invalidate` for the index: most files are still the files it had, so the
  /// cached list stays worth drawing while the re-walk runs.
  Future<void> mergeBranch(EnvironmentPath repo, String branch) async {
    await _gitFor(repo).mergeBranch(repo, branch);
    onWorkingTreeChanged?.call(repo);
  }

  /// Brings [repo]'s checked-out branch level with [ref], fast-forwarding when
  /// it can. The index is touched whether or not the merge succeeded: one that
  /// stopped on a conflict has already rewritten files.
  Future<void> mergeRef(EnvironmentPath repo, String ref) async {
    try {
      await _gitFor(repo).mergeRef(repo, ref);
    } finally {
      onWorkingTreeChanged?.call(repo);
    }
  }

  /// Undoes a merge that stopped with conflicts; see `GitService.abortMerge`
  /// for why this reports rather than throws.
  Future<bool> abortMerge(EnvironmentPath repo) async {
    final restored = await _gitFor(repo).abortMerge(repo);
    if (restored) onWorkingTreeChanged?.call(repo);
    return restored;
  }

  /// Moves [branch] back to [sha]; `undo_run.dart` refuses once any of those
  /// commits is on a remote. `update-ref`, so no file or index entry moves.
  Future<void> moveBranchTo(
    EnvironmentPath repo, {
    required String branch,
    required String sha,
  }) => _gitFor(repo).updateRef(repo, 'refs/heads/$branch', sha);

  /// Stages [paths], or everything when none are named.
  ///
  /// The index is not the working tree, so nothing here tells Quick Open its
  /// files moved — only [discard] and [pull] rewrite what is on disk.
  Future<void> stage(EnvironmentPath repo, {List<String> paths = const []}) =>
      paths.isEmpty
      ? _gitFor(repo).stageAll(repo)
      : _gitFor(repo).stage(repo, paths);

  Future<void> unstage(EnvironmentPath repo, List<String> paths) =>
      _gitFor(repo).unstage(repo, paths);

  /// Throws away the changes to [paths]: tracked ones are rewound, untracked
  /// ones are deleted. Split by the caller, because they are different acts and
  /// the second has no undo — see `GitService.deleteUntracked`.
  Future<void> discard(
    EnvironmentPath repo, {
    List<String> tracked = const [],
    List<String> untracked = const [],
  }) async {
    try {
      await _gitFor(repo).discard(repo, tracked);
      await _gitFor(repo).deleteUntracked(repo, untracked);
    } finally {
      // Even a half-done discard has rewritten files.
      if (tracked.isNotEmpty || untracked.isNotEmpty) {
        onWorkingTreeChanged?.call(repo);
      }
    }
  }

  /// Commits what is staged. Throws [GitException] carrying git's own sentence
  /// — "nothing to commit" and a rejected hook both arrive this way.
  Future<void> commit(EnvironmentPath repo, String message) =>
      _gitFor(repo).commit(repo, message);

  Future<void> fetch(EnvironmentPath repo) => _gitFor(repo).fetch(repo);

  /// Brings the upstream in. Fast-forward only unless the caller chose
  /// otherwise; either way the working tree has moved by the end.
  Future<void> pull(
    EnvironmentPath repo, {
    bool rebase = false,
    bool merge = false,
  }) async {
    try {
      await _gitFor(repo).pull(repo, rebase: rebase, merge: merge);
    } finally {
      onWorkingTreeChanged?.call(repo);
    }
  }

  /// Pushes the checked-out branch. [remote] and [branch] together publish a
  /// branch that has no upstream yet (`push -u`).
  Future<void> push(EnvironmentPath repo, {String? remote, String? branch}) =>
      _gitFor(repo).push(repo, remote: remote, branch: branch);

  /// Scans the commits a push of [repo] would send for secrets, where [repo]
  /// lives. Never throws.
  Future<SecretScan> scanOutgoingSecrets(EnvironmentPath repo) =>
      _gitFor(repo).scanOutgoingSecrets(repo);
}
