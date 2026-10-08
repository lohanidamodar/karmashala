part of 'fake_data_server.dart';

/// The git a [FakeDataServer] does (slice 3b) — a checkout's reads and
/// writes, worktrees, their cleanup, a project's folders and GitHub — as a
/// test scripts it. Nothing runs git: a test seeds what each checkout holds
/// (keyed by [Checkout], so a path's spelling does not matter) or answers a
/// request itself with [answer]. Every write is recorded in [asked] and told
/// to every link as a [CheckoutTouched], the way the server tells it.
class FakeGitWork {
  FakeGitWork._(this._server);

  final FakeDataServer _server;

  /// Every git request, in the order asked.
  final asked = <GitWorkRequest<Object?>>[];

  /// The kinds asked, in order — what a cost test counts.
  List<String> get kinds => [for (final r in asked) r.kind];

  /// Answers a request before the defaults do; return [unhandled] to fall
  /// through. May be async, and may throw a [DataRefused].
  FutureOr<Object?> Function(GitWorkRequest<Object?> request)? answer;

  /// What [answer] returns to leave a request to the defaults.
  static const Object unhandled = _Unhandled();

  /// A refusal the next request of that kind gets, once.
  final refusals = <String, DataRefused>{};

  // What each checkout holds.
  final statuses = <Checkout, WorkingTreeStatus>{};
  final fileStats = <Checkout, Map<String, FileDiffStat>>{};

  /// `(checkout, path, staged)` → the diff; a missing one is empty.
  final diffs = <(Checkout, String?, bool), String>{};
  final untracked = <(Checkout, String), String>{};
  final logs = <Checkout, List<GitCommit>>{};
  final branches = <Checkout, String?>{};
  final heads = <Checkout, String?>{};
  final revisions = <(Checkout, String), String?>{};
  final aheadBehinds = <(Checkout, String), AheadBehind?>{};
  final remoteBranches = <(Checkout, String), List<String>?>{};
  final origins = <Checkout, RepositoryOrigin>{};
  final mergesInProgress = <Checkout, bool?>{};
  final blobShas = <Checkout, Map<String, String>>{};
  final presences = <Checkout, GitPresence>{};
  final deliveries = <Checkout, SessionDelivery>{};
  final worktrees = <Checkout, List<GitWorktree>>{};
  final labels = <String, CheckoutLabel>{};
  final pullRequests = <(Checkout, String), PullRequestReading>{};
  final overviews = <Checkout, GitHubOverview>{};

  /// What a push answers: the scan's sentence.
  String pushNote = 'gitleaks found no secrets.';

  /// Whether `git.abortMerge` restores the tree.
  bool abortRestores = true;

  /// What a scan of a project's folder finds: a created project's checkouts,
  /// a rescan's new ones.
  var found = <DiscoveredRepository>[];

  WorktreeCleanupReport? cleanupReport;
  WorktreeCleanupLog cleanupLog = WorktreeCleanupLog.empty;

  /// The changes of [checkout]: its status's.
  List<FileChange> changesOf(EnvironmentPath checkout) =>
      statuses[Checkout(checkout)]?.changes ?? const [];

  /// Puts [changes] in [checkout]'s working tree.
  void setChanges(EnvironmentPath checkout, List<FileChange> changes) {
    final status = statuses[Checkout(checkout)];
    statuses[Checkout(checkout)] = WorkingTreeStatus(
      branch: status?.branch,
      upstream: status?.upstream,
      aheadOfUpstream: status?.aheadOfUpstream,
      behindUpstream: status?.behindUpstream,
      changes: changes,
    );
  }

  /// Tells every link [checkout] may read differently now, as the server
  /// does after a write, a worktree or an agent's turn there.
  void touch(
    EnvironmentPath checkout, {
    CheckoutTouchCause cause = CheckoutTouchCause.gitWrite,
  }) => _server._tell(null, [
    CheckoutTouched(
      environmentId: checkout.environmentId,
      path: checkout.path,
      cause: cause,
    ),
  ]);

  /// Tells every link creation [id]'s record now.
  void creationMoved(
    String id,
    EnvironmentPath repo,
    WorktreeCreationRecord record,
  ) => _server._tell(null, [WorktreeCreationChanged(id, repo, record)]);

  /// Tells every link cleanup swept, with [log].
  void swept(WorktreeCleanupLog log) {
    cleanupLog = log;
    _server._tell(null, [WorktreeCleanupChanged(log)]);
  }

  /// What a worktree creation makes, by default a worktree folder beside the
  /// checkout with every stage done.
  Future<CreatedWorktree> Function(WorktreeCreate request)? onCreate;

  Future<Object?> _handle(GitWorkRequest<Object?> request) async {
    asked.add(request);
    final refusal = refusals.remove(request.kind);
    if (refusal != null) throw refusal;
    final scripted = answer;
    if (scripted != null) {
      final value = await scripted(request);
      if (!identical(value, unhandled)) return value;
    }
    return _default(request);
  }

  EnvironmentPath _path(CheckoutRef ref) =>
      ref.directory ??
      _server.repositoryRows.getById(ref.repositoryId!)?.path ??
      (throw DataRefused.notFound('no checkout with id ${ref.repositoryId}'));

  Future<Object?> _default(GitWorkRequest<Object?> request) async {
    switch (request) {
      case GitPresenceOf(:final checkouts):
        return [
          for (final c in checkouts)
            presences[Checkout(c)] ?? GitPresence.repository,
        ];
      case WorktreeLabels(:final repositoryIds) when runner != null:
        return readCheckoutLabels([
          for (final id in repositoryIds) ?_server.repositoryRows.getById(id),
        ], GitService(runner!).listWorktrees);
      case WorktreeLabels(:final repositoryIds):
        return {for (final id in repositoryIds) id: ?labels[id]};
      case WorktreeCreationCancel() || WorktreeAgentSettled():
        return const DataAck();
      case ScratchCheckoutCreate():
        // Scripted through [answer] by the tests that need one; the default
        // fake has no disk to make a folder on.
        throw const DataRefused.unavailable(
          'no scratch folder can be made here',
        );
      case WorktreeCleanupPreview() || WorktreeCleanupSweep():
        return cleanupReport ??
            WorktreeCleanupReport(
              at: DateTime.utc(2026),
              dryRun: request is WorktreeCleanupPreview,
              verdicts: const [],
            );
      case WorktreeCleanupLogRead():
        return cleanupLog;
      case ProjectFoldersCreate(
        :final projectName,
        :final root,
        :final workspaceId,
      ):
        // Written as the server's own write, so every link is told.
        final reply = _server._handle(
          FakeDataLink._(_server),
          ProjectCreate(
            projectName: projectName,
            root: root,
            workspaceId: workspaceId,
            found: found,
          ),
        );
        return reply.value;
      case ProjectRescan(:final projectId):
        return _server
            ._handle(
              FakeDataLink._(_server),
              CheckoutsAdd(projectId: projectId, found: found),
            )
            .value;
      case ProjectMove(:final projectId, :final projectName, :final root):
        return _server
            ._handle(
              FakeDataLink._(_server),
              ProjectUpdate(
                id: projectId,
                projectName: projectName,
                root: root,
                defaultRepositoryId: request.defaultRepositoryId,
                clearDefaultRepository: request.clearDefaultRepository,
              ),
            )
            .value;
      case final CheckoutRequest<Object?> r:
        return _checkout(r, _path(r.checkout));
    }
  }

  /// When set, a checkout's reads and writes that no map above answers run
  /// through the package's own `GitService` over this runner — as the server
  /// does — so a test can describe a repository in git's own output.
  CommandRunner? runner;

  /// [factory], after making its fallback runner this server's [runner] — for
  /// a test that describes its repository to the app's runner factory: the
  /// git it describes is now asked of the server, which runs it there.
  FakeCommandRunnerFactory serve(FakeCommandRunnerFactory factory) {
    runner = factory.fallback;
    return factory;
  }

  Future<Object?> _checkout(
    CheckoutRequest<Object?> r,
    EnvironmentPath at,
  ) async {
    final c = Checkout(at);
    final git = runner == null ? null : GitService(runner!);
    if (git != null && (r is WorktreeCreate || r is WorktreeRemove)) {
      // The package's own worktree service over the runner, no setup — as
      // the server's, where the test describes git's side.
      final environment =
          _server.environmentRows.getById(at.environmentId) ??
          (throw DataRefused.notFound('no environment ${at.environmentId}'));
      final service = WorktreeService(
        runnerFactory: FakeCommandRunnerFactory(
          fallback: runner! as FakeCommandRunner,
        ),
        environmentOf: (_) => environment,
      );
      try {
        if (r case final WorktreeCreate create) {
          final created = await service.create(
            repo: at,
            worktreeName: create.worktreeName,
            branch: create.branch,
            baseRef: create.baseRef,
            launchesAgent: create.launchesAgent,
          );
          touch(at, cause: CheckoutTouchCause.worktree);
          return CreatedWorktree(
            worktree: created.worktree,
            record: created.tracker.record,
          );
        }
        final remove = r as WorktreeRemove;
        final teardown = await service.remove(
          at,
          remove.worktree,
          force: remove.force,
        );
        touch(at, cause: CheckoutTouchCause.worktree);
        return teardown?.said;
      } on GitException catch (e) {
        throw DataRefused(DataRefusalCode.failed, e.message);
      }
    }
    if (git != null) {
      final ran = await _viaGit(git, r, at);
      if (!identical(ran, unhandled)) return ran;
    }
    switch (r) {
      // No branches recorded: the dialog falls back to the worktree list.
      case GitBranches():
        return const <Object>[];
      case GitStatusOf():
        return statuses[c] ?? const WorkingTreeStatus();
      case GitChangesOf():
        return statuses[c]?.changes ?? const <FileChange>[];
      case GitFileDiffStats():
        return fileStats[c] ?? const <String, FileDiffStat>{};
      case GitDiff(:final path, :final staged):
        return diffs[(c, path, staged)] ?? '';
      case GitDiffUntracked(:final path):
        return untracked[(c, path)] ?? '';
      case GitLog(:final limit):
        return (logs[c] ?? const <GitCommit>[]).take(limit).toList();
      case GitBranch():
        return branches[c] ?? statuses[c]?.branch;
      case GitHead():
        return heads[c];
      case GitRevParse(:final rev):
        return revisions[(c, rev)];
      case GitAheadBehind(:final base):
        return aheadBehinds[(c, base)];
      case GitRemoteBranchesContaining(:final rev):
        return remoteBranches.containsKey((c, rev))
            ? remoteBranches[(c, rev)]
            : const <String>[];
      case GitOriginFacts():
        return origins[c] ?? RepositoryOrigin.none;
      case GitMergeInProgress():
        return mergesInProgress[c] ?? false;
      case GitBlobShas(:final paths):
        final known = blobShas[c] ?? const {};
        return {for (final p in paths) p: ?known[p]};
      case GitDelivery():
        return deliveries[c] ?? SessionDelivery.unknown;
      case GitStage() ||
          GitUnstage() ||
          GitDiscard() ||
          GitCommitStaged() ||
          GitFetch() ||
          GitPull() ||
          GitMerge() ||
          GitMoveBranch():
        touch(at);
        return const DataAck();
      case GitPush():
        touch(at);
        return pushNote;
      case GitAbortMerge():
        touch(at);
        return abortRestores;
      case WorktreesOf():
        return worktrees[c] ?? const <GitWorktree>[];
      case final WorktreeCreate create:
        final made = onCreate;
        final created = made != null
            ? await made(create)
            : CreatedWorktree(
                worktree: GitWorktree(
                  path: EnvironmentPath(
                    environmentId: at.environmentId,
                    path:
                        '${at.path}/.karmashala-worktrees/'
                        '${create.worktreeName}',
                  ),
                  branch: create.branch,
                ),
                record: WorktreeCreationRecord.initial(),
              );
        touch(at, cause: CheckoutTouchCause.worktree);
        return created;
      case WorktreeRemove():
        touch(at, cause: CheckoutTouchCause.worktree);
        return null;
      case GitHubOverviewOf():
        return overviews[c] ?? const GitHubOverview();
      case GitHubPullRequest(:final branch):
        return pullRequests[(c, branch)] ?? PullRequestReading.none;
      case GitHubMarkReady():
        return const DataAck();
      case GitHubCreatePr():
        return 'https://github.com/o/r/pull/1';
      case GitHubRuns():
        return const <WorkflowRun>[];
      case GitHubRunLog(:final runId):
        return boundRunLog(runId, '');
    }
  }
}

/// [r] answered by [git] the way the server's `CheckoutGit` answers it, or
/// [FakeGitWork.unhandled] for a request that is not git's to answer here.
Future<Object?> _viaGit(
  GitService git,
  CheckoutRequest<Object?> r,
  EnvironmentPath at,
) async {
  try {
    return await _viaGitUnguarded(git, r, at);
  } on NotAGitRepository catch (e) {
    throw DataRefused.notFound('${e.directory.path} is not a git repository');
  } on GitException catch (e) {
    throw DataRefused(DataRefusalCode.failed, e.message);
  } on CommandException catch (e) {
    throw DataRefused.unavailable(e.message);
  }
}

Future<Object?> _viaGitUnguarded(
  GitService git,
  CheckoutRequest<Object?> r,
  EnvironmentPath at,
) async {
  Future<DataAck> ack(Future<void> work) async {
    await work;
    return const DataAck();
  }

  return switch (r) {
    GitStatusOf() => git.statusWithBranch(at),
    GitChangesOf() => git.status(at),
    GitFileDiffStats() => git.fileDiffStats(at),
    GitDiff(:final path, :final staged, :final base) => git.diff(
      at,
      path: path,
      staged: staged,
      base: base,
    ),
    GitDiffUntracked(:final path) => () async {
      if (await git.isTracked(at, path)) return '';
      return git.diffUntracked(at, path);
    }(),
    GitLog(:final limit) => git.log(at, limit: limit),
    GitBranch() => git.currentBranch(at),
    GitRevParse(:final rev) => git.revParse(at, rev),
    GitAheadBehind(:final base) => git.aheadBehind(at, base: base),
    GitRemoteBranchesContaining(:final rev) => git.remoteBranchesContaining(
      at,
      rev,
    ),
    GitOriginFacts() => () async {
      final url = await git.remoteUrl(at);
      return url == null
          ? RepositoryOrigin.none
          : RepositoryOrigin(url: url, head: await git.originHead(at));
    }(),
    GitBlobShas(:final paths) => git.hashObjects(at, paths),
    GitDelivery(:final repository) => _deliveryVia(git, at, repository),
    WorktreesOf() => git.listWorktrees(at),
    GitHubPullRequest(:final branch) => _pullRequestVia(
      _ScriptedGh(git.runner),
      at,
      branch,
    ),
    GitHubOverviewOf() => () async {
      final gh = _ScriptedGh(git.runner);
      return GitHubOverview(
        repository: await gh.getRepository(at),
        pullRequests: await gh.listPullRequests(at),
        issues: await gh.listIssues(at),
      );
    }(),
    GitHubMarkReady(:final number) => ack(
      _ScriptedGh(git.runner).markPullRequestReady(at, number: number),
    ),
    GitStage(:final paths) => ack(
      paths.isEmpty ? git.stageAll(at) : git.stage(at, paths),
    ),
    GitUnstage(:final paths) => ack(git.unstage(at, paths)),
    GitDiscard(:final tracked, :final untracked) => ack(() async {
      await git.discard(at, tracked);
      await git.deleteUntracked(at, untracked);
    }()),
    GitCommitStaged(:final message, :final all) => ack(() async {
      if (all) await git.stageAll(at);
      await git.commit(at, message);
    }()),
    GitMerge(:final ref, :final commit) => ack(
      commit ? git.mergeBranch(at, ref) : git.mergeRef(at, ref),
    ),
    GitAbortMerge() => git.abortMerge(at),
    GitMoveBranch(:final branch, :final sha) => ack(
      git.updateRef(at, 'refs/heads/$branch', sha),
    ),
    _ => FakeGitWork.unhandled,
  };
}

/// A branch's pull request as the server's `ServerGit` reads it: a `gh` that
/// could not tell is no pull request; the policy only for an open one, the
/// protection only when a merge reads `BLOCKED`.
Future<PullRequestReading> _pullRequestVia(
  _ScriptedGh gh,
  EnvironmentPath at,
  String branch,
) async {
  Future<T?> orNull<T>(Future<T?> Function() probe) async {
    try {
      return await probe();
    } on Object {
      return null;
    }
  }

  final pr = await orNull(() => gh.pullRequestFor(at, branch: branch));
  if (pr == null || !pr.isOpen) return PullRequestReading(pullRequest: pr);
  final policy =
      await orNull(() => gh.forgePolicyFor(at, number: pr.number)) ??
      kUnknownForgePolicy;
  final base = pr.baseRefName;
  final protection =
      pr.mergeStateStatus == MergeStateStatus.blocked && base != null
      ? await orNull(() => gh.branchProtectionFor(at, branch: base)) ??
            BranchProtection.unknown
      : BranchProtection.unknown;
  return PullRequestReading(
    pullRequest: pr.withUnresolvedReviewThreads(policy.unresolvedReviewThreads),
    strategies: policy.strategies,
    protection: protection,
  );
}

/// The local half of a delivery reading, measured as the server's
/// `CheckoutDeliveryReader` measures it; every failed probe is null.
Future<SessionDelivery> _deliveryVia(
  GitService git,
  EnvironmentPath at,
  EnvironmentPath? repository,
) async {
  Future<T?> orNull<T>(Future<T?> Function() probe) async {
    try {
      return await probe();
    } on Object {
      return null;
    }
  }

  Future<SessionDelivery> local(
    EnvironmentPath dir,
    EnvironmentPath repo,
  ) async {
    final status = await orNull(() => git.statusWithBranch(dir));
    if (status == null) return SessionDelivery.unknown;
    final url = await orNull(() => git.remoteUrl(repo));
    final head = url == null ? null : await orNull(() => git.originHead(repo));
    final origin = RepositoryOrigin(url: url, head: head);
    final ab = head == null
        ? null
        : await orNull(() => git.aheadBehind(dir, base: head));
    final lines = await orNull(() => git.diffStat(dir, base: head));
    return SessionDelivery(
      branch: status.branch,
      baseBranch: head,
      upstream: status.upstream,
      hasRemote: origin.hasRemote,
      remote: RemoteRepo.parse(url),
      defaultBranch: origin.defaultBranch,
      dirtyFiles: status.changes.length,
      lines: lines,
      aheadOfBase: ab?.ahead,
      behindBase: ab?.behind,
      unpushed: status.aheadOfUpstream,
    );
  }

  if (repository == null) return local(at, at);
  final own = await local(at, repository);
  if (own.baseBranch != null) return own;
  final base = (await local(repository, repository)).branch;
  if (base == null || base == own.branch) return own;
  final ab = await orNull(() => git.aheadBehind(at, base: base));
  final lines = await orNull(() => git.diffStat(at, base: base));
  return own.copyWith(
    baseBranch: base,
    aheadOfBase: ab?.ahead,
    behindBase: ab?.behind,
    lines: lines,
  );
}

final class _Unhandled {
  const _Unhandled();
}

/// GitHub as the app's tests script it: `gh` answers through the fake
/// runner, read with the package's parsers. The server asks GitHub's API
/// itself; these tests are about what the app does with the answers.
class _ScriptedGh {
  _ScriptedGh(this.runner);

  final CommandRunner runner;

  Future<CommandResult> _gh(EnvironmentPath at, List<String> args) =>
      runner.run(
        CommandRequest(executable: 'gh', arguments: args, workingDirectory: at),
      );

  Future<String> _ok(EnvironmentPath at, List<String> args) async {
    final result = await _gh(at, args);
    if (!result.ok) throw GitHubException(result.stderr.trim());
    return result.stdout;
  }

  Future<GitHubRepo?> getRepository(EnvironmentPath at) async => parseGhRepo(
    await _ok(at, [
      'repo',
      'view',
      '--json',
      'nameWithOwner,description,url,isPrivate,stargazerCount,defaultBranchRef',
    ]),
  );

  Future<List<PullRequest>> listPullRequests(EnvironmentPath at) async =>
      parseGhPullRequests(
        await _ok(at, [
          'pr',
          'list',
          '--json',
          'number,title,state,author,url',
        ]),
      );

  Future<List<Issue>> listIssues(EnvironmentPath at) async => parseGhIssues(
    await _ok(at, ['issue', 'list', '--json', 'number,title,state']),
  );

  Future<PullRequestSnapshot?> pullRequestFor(
    EnvironmentPath at, {
    required String branch,
  }) async {
    final result = await _gh(at, ['pr', 'view', branch, '--json', 'all']);
    if (!result.ok) {
      if (mentionsNoPullRequest(result.stderr)) return null;
      throw GitHubException(result.stderr.trim());
    }
    return parseGhPullRequestView(result.stdout);
  }

  Future<ForgePolicy> forgePolicyFor(
    EnvironmentPath at, {
    required int number,
  }) async => parseForgePolicy(
    (await _gh(at, ['api', 'graphql', '-F', 'number=$number'])).stdout,
  );

  Future<BranchProtection> branchProtectionFor(
    EnvironmentPath at, {
    required String branch,
  }) async {
    final result = await _gh(at, [
      'api',
      'repos/{owner}/{repo}/branches/$branch/protection',
    ]);
    if (!result.ok) {
      return mentionsForbidden('${result.stdout}\n${result.stderr}')
          ? BranchProtection.forbidden
          : BranchProtection.unknown;
    }
    return parseBranchProtection(result.stdout, branch: branch);
  }

  Future<void> markPullRequestReady(
    EnvironmentPath at, {
    required int number,
  }) => _ok(at, ['pr', 'ready', '$number']);
}
