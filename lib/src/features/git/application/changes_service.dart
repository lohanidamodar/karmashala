import '../../../core/process/command_runner_factory.dart';
import '../../environments/data/execution_environment_dao.dart';
import '../../environments/domain/environment_path.dart';
import '../data/git_files.dart';
import '../data/git_origin_reader.dart';
import '../data/git_service.dart';
import '../domain/diff_stat.dart';
import '../domain/file_change.dart';
import '../domain/git_commit.dart';
import '../domain/repository_origin.dart';
import '../domain/working_tree_status.dart';

/// Notified with a repository whose working tree this service has just
/// rewritten. Quick Open's index marks that root stale; see [CheckoutMoved] for
/// why the notice is a callback and not the index itself.
typedef WorkingTreeChanged = void Function(EnvironmentPath repo);

/// High-level access to a repository's working-tree changes and diffs, resolving
/// the correct runner for the repository's environment. Git is the source of
/// truth and there is no editor (ADR 0004).
///
/// **Almost read-only, and that is a rule rather than an accident.** Committing
/// and pushing are things the *agent* does: the delivery strip's `Commit` and
/// `Push` send a prompt into the session verbatim, so the model writes the
/// message with the context it just worked in and reports a rejected push in
/// the transcript. `commitAll` and `push` wrappers sat here with no caller from
/// the day they were written until Loop 67 deleted them; they were a second,
/// silent way to do what the strip already asks for. `GitService` keeps
/// `stageAll`/`commit`/`push` — the data layer's vocabulary is not an offer.
/// [mergeBranch] is the exception, and it exists for the fan-out comparison,
/// which merges a winning branch on the user's explicit instruction.
/// [mergeRef] and [abortMerge] are the second, and they exist together: the
/// delivery strip's `Update` brings a branch level with its base, and a merge
/// that stops on a conflict must be undone rather than left in the working tree
/// an agent may be about to run in. Neither is a general "let the app write to
/// git" licence — both are one user press with one meaning.
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

  GitService _gitFor(EnvironmentPath repo) {
    final env = environmentDao.getById(repo.environmentId);
    if (env == null) {
      throw GitException('Unknown environment: ${repo.environmentId}');
    }
    return GitService(runnerFactory.forEnvironment(env));
  }

  /// Changed files in [repo].
  Future<List<FileChange>> changes(EnvironmentPath repo) =>
      _gitFor(repo).status(repo);

  /// The branch, its upstream, their divergence and the changed files, in one
  /// process. What a delivery row reads.
  Future<WorkingTreeStatus> statusWithBranch(EnvironmentPath repo) =>
      _gitFor(repo).statusWithBranch(repo);

  /// The default branch this clone recorded for `origin`, or `null`.
  Future<String?> originHead(EnvironmentPath repo) =>
      _gitFor(repo).originHead(repo);

  /// Both of [repo]'s `origin` facts — the URL and the default branch — from
  /// **two file reads rather than two subprocesses**, falling back to git for
  /// whichever the files could not answer.
  ///
  /// This is what every visible Explorer row's delivery reading funnels into,
  /// once per repository, so it is the one place in this service where reading
  /// a file instead of running `git` is worth the code. `.git/config` carries
  /// `remote.origin.url` on a line; `origin/HEAD` is a line in
  /// `refs/remotes/origin/HEAD` or absent from `packed-refs`. Neither read
  /// costs a `CreateProcessW`, which — see `checkout_probe_queue.dart` — is
  /// charged to the calling thread whatever the future looks like.
  ///
  /// **Falls back per fact, not per call**, and falls back on any uncertainty
  /// at all: an SSH repository this process cannot open, a `.git` that is
  /// neither a directory with a config nor a pointer file, a config with
  /// `include`/`insteadOf` indirection in it, a `reftable` repository with no
  /// `refs/` tree. `GitOriginReader` documents each one. A wrong answer here is
  /// worse than a slow one — the URL decides whether a row looks for a pull
  /// request, and `origin/HEAD` is the base every ahead/behind count is
  /// measured against.
  ///
  /// It lives here rather than in `GitService` because the environment is what
  /// decides whether the files are reachable at all, and this is the layer that
  /// holds it.
  Future<RepositoryOrigin> originFacts(EnvironmentPath repo) async {
    final env = environmentDao.getById(repo.environmentId);
    if (env == null) {
      throw GitException('Unknown environment: ${repo.environmentId}');
    }
    final reading = await GitOriginReader(
      files: files,
      hostPathOf: hostPathMapperFor(env),
    ).read(repo.path);

    // `_gitFor` only where a fact is missing, so a repository whose files
    // answered never builds a runner it has nothing to run.
    final url = reading.url.known
        ? reading.url.value
        : await _gitFor(repo).remoteUrl(repo);
    if (url == null) return RepositoryOrigin.none;
    return RepositoryOrigin(
      url: url,
      head: reading.head.known
          ? reading.head.value
          : await _gitFor(repo).originHead(repo),
    );
  }

  /// The current branch of [repo], or `null` if detached/unknown.
  Future<String?> currentBranch(EnvironmentPath repo) =>
      _gitFor(repo).currentBranch(repo);

  /// The `origin` remote URL of [repo], or `null` if there is none.
  Future<String?> remoteUrl(EnvironmentPath repo) =>
      _gitFor(repo).remoteUrl(repo);

  /// Commits on [repo]'s current branch that [base] does not have; `null` when
  /// git could not answer.
  Future<int?> commitsAhead(EnvironmentPath repo, {required String base}) =>
      _gitFor(repo).commitsAhead(repo, base: base);

  /// Lines added and removed in [repo], against [base] when one is given.
  Future<DiffStat?> diffStat(EnvironmentPath repo, {String? base}) =>
      _gitFor(repo).diffStat(repo, base: base);

  /// How [repo] stands against [base] in both directions; `null` when git could
  /// not answer.
  Future<AheadBehind?> aheadBehind(
    EnvironmentPath repo, {
    required String base,
  }) => _gitFor(repo).aheadBehind(repo, base: base);

  /// Resolves [rev] in [repo], or `null` when it names nothing. Asking for
  /// `refs/heads/<name>` is how "does this branch exist" is asked.
  Future<String?> revParse(EnvironmentPath repo, String rev) =>
      _gitFor(repo).revParse(repo, rev);

  /// The remote-tracking branches holding [rev]; `null` when git could not
  /// answer, empty when nothing outside this machine has those commits.
  Future<List<String>?> remoteBranchesContaining(
    EnvironmentPath repo,
    String rev,
  ) => _gitFor(repo).remoteBranchesContaining(repo, rev);

  /// The upstream of [branch] in [repo] (`origin/work`), or `null`.
  Future<String?> upstreamOf(EnvironmentPath repo, String branch) =>
      _gitFor(repo).upstreamOf(repo, branch);

  /// Unified diff for [repo], optionally limited to [path] / staged changes.
  Future<String> diff(
    EnvironmentPath repo, {
    String? path,
    bool staged = false,
  }) => _gitFor(repo).diff(repo, path: path, staged: staged);

  /// The content fingerprint of each of [paths] as they stand on disk, for the
  /// review-thread anchors. A path git could not hash is absent from the map,
  /// which the caller must read as "cannot tell" and never as unchanged.
  Future<Map<String, String>> blobShas(
    EnvironmentPath repo,
    List<String> paths,
  ) => _gitFor(repo).hashObjects(repo, paths);

  /// Recent commits for [repo].
  Future<List<GitCommit>> log(EnvironmentPath repo, {int limit = 20}) =>
      _gitFor(repo).log(repo, limit: limit);

  /// Merges [branch] into [repo]'s checked-out branch. The one write here; see
  /// the class doc for why it is the only one.
  ///
  /// `touch` rather than `invalidate` for the index: the directory is still the
  /// same directory and most of its files are still the files it had, so the
  /// cached list stays worth drawing for one frame while the re-walk runs.
  Future<void> mergeBranch(EnvironmentPath repo, String branch) async {
    await _gitFor(repo).mergeBranch(repo, branch);
    onWorkingTreeChanged?.call(repo);
  }

  /// Brings [repo]'s checked-out branch level with [ref], fast-forwarding when
  /// it can. See `GitService.mergeRef` for why this is not [mergeBranch].
  ///
  /// The index is touched on the way *out* whether or not the merge succeeded:
  /// a merge that stopped on a conflict has already rewritten files in the
  /// working tree, so a cached listing taken before it is stale either way.
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
}
