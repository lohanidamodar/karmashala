import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:karmashala_core/util.dart' show Clock;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_git/github.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_git/store.dart' show WorktreeSetupDao;
import 'package:karmashala_git/worktrees.dart';
import 'package:karmashala_projects/karmashala_projects.dart' show Project;
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart' show SessionDao;
import 'package:karmashala_store/database.dart';

import '../data/data_service.dart';
import '../data/git_work.dart';
import '../mcp/tools/checkout_reach.dart';
import '../mcp/tools/project_folders.dart';
import 'checkout_git.dart';
import 'worktree_cleanup.dart';
import 'worktree_cleanup_service.dart';
import 'worktree_creations.dart';

/// Set to `off` in a server's environment, worktree cleanup sweeps only when
/// a client asks: no schedule (live tests).
const String kWorktreeCleanupVariable = 'KARMASHALA_WORKTREE_CLEANUP';

/// **Everything git the server does for its clients** (slice 3b), built once
/// by `serve` and answering every `GitWorkRequest`: a checkout's reads and
/// writes ([checkouts]), worktrees ([creations] over [worktrees]), their
/// cleanup and its schedule ([cleanup]) and GitHub through `gh`. What moves a
/// checkout is told to every client as `CheckoutTouched` — a write here, a
/// worktree made or removed, an agent's turn ending there — so nothing polls.
class ServerGit implements GitWork {
  ServerGit({
    required AppDatabase database,
    required this.data,
    required this.reach,
    required this.worktrees,
    required this.folders,
    required bool Function(String sessionId) hostsSession,
    required Iterable<String> Function() livePaneDirectories,
    DateTime Function()? clock,
    bool onItsOwn = true,
    void Function(String message)? log,
  }) : _sessions = SessionDao(database),
       _repositories = RepositoryDao(database),
       _projects = ProjectDao(database),
       _setups = WorktreeSetupDao(database) {
    final now = clock ?? _utcNow;
    checkouts = CheckoutGit(
      reach: reach,
      repositories: _repositories,
      tell: data.announce,
      identify: (path, canonicalId) => data.applyAsServer(
        CheckoutsIdentify(path: path, canonicalId: canonicalId),
      ),
    );
    creations = ClientWorktreeCreations(
      worktrees: worktrees,
      tell: data.announce,
      touched: (path) => checkouts.touched(path, CheckoutTouchCause.worktree),
    );
    cleanup = WorktreeCleanup(
      data: data,
      clock: now,
      onItsOwn: onItsOwn,
      service: WorktreeCleanupService(
        projects: _projects.getAll,
        repositoriesOf: _repositories.getByProject,
        presenceOf: reach.presenceOf,
        familyKeyOf: checkouts.familyKey,
        environmentKind: (id) => reach.environment(id)?.kind,
        gitFor: worktrees.gitFor,
        removeIfClean: (repo, worktree) async {
          try {
            await worktrees.removeIfClean(repo, worktree);
          } finally {
            checkouts.touched(repo, CheckoutTouchCause.worktree);
          }
        },
        sessions: _sessions.getAll,
        // A status that claims a run counts even with no process behind it:
        // "we lost track of it" is not evidence nothing works there.
        isLive: (session) =>
            session.status.claimsLive || hostsSession(session.id),
        liveTerminalDirectories: livePaneDirectories,
        lastEventAt: (ids) async =>
            data.applyAsServer(SessionEventsLatest([...ids])),
        createdAt: _createdAt,
        clock: _FunctionClock(now),
        log: log,
        onRemoved: (entry, sessionIds) {
          cleanup.record(entry);
          if (!entry.removed) return;
          // The record the archive action leaves: the row and transcript
          // survive, and nothing offers to resume into a directory gone.
          for (final id in sessionIds) {
            try {
              data.applyAsServer(
                SessionEdit(id, SessionPatch.archive(entry.at)),
              );
            } on DataRefused {
              // The row went meanwhile; nothing to mark.
            }
          }
        },
      ),
    );
  }

  static DateTime _utcNow() => DateTime.now().toUtc();

  final DataService data;

  /// Where git runs: this machine, WSL from a Windows server, and SSH
  /// through the runners it was given.
  final CheckoutReach reach;

  /// The server's one worktree service: creation with its setup, removal
  /// with its teardown.
  final WorktreeService worktrees;

  /// A project's folders: cloning, scanning, retiring what is gone.
  final ProjectFolders folders;

  final SessionDao _sessions;
  final RepositoryDao _repositories;
  final ProjectDao _projects;
  final WorktreeSetupDao _setups;

  late final CheckoutGit checkouts;
  late final ClientWorktreeCreations creations;
  late final WorktreeCleanup cleanup;

  /// Answers the clients' git work from now on, and keeps the cleanup's
  /// schedule.
  void attach() {
    data.gitWork = this;
    cleanup.start();
  }

  Future<void> stop() async {
    cleanup.stop();
    await creations.close();
    if (identical(data.gitWork, this)) data.gitWork = null;
  }

  /// An agent's turn ended in session [sessionId]: where it works may read
  /// differently now.
  void turnEnded(String sessionId) {
    final session = _sessions.getById(sessionId);
    if (session == null) return;
    final directory =
        session.worktree ??
        session.workingDirectory ??
        _repositories.getById(session.repositoryId)?.path;
    if (directory == null) return;
    checkouts.touched(directory, CheckoutTouchCause.turnEnded);
  }

  @override
  Future<Object?> handle(GitWorkRequest<Object?> request) async {
    try {
      return await _handle(request);
    } on Object catch (error) {
      throw gitRefusalOf(error);
    }
  }

  Future<Object?> _handle(
    GitWorkRequest<Object?> request,
  ) async => switch (request) {
    GitPresenceOf(:final checkouts) => Future.wait([
      for (final checkout in checkouts)
        reach.presenceOf(checkout).catchError((Object _) {
          return GitPresence.unknown;
        }),
    ]),
    WorktreeLabels(:final repositoryIds) => readCheckoutLabels(
      [for (final id in repositoryIds) ?_repositories.getById(id)],
      worktrees.list,
      familyKey: checkouts.familyKey,
    ),
    WorktreeCreationCancel(:final creationId) => () {
      creations.cancel(creationId);
      return const DataAck();
    }(),
    WorktreeAgentSettled(:final creationId, :final error) => () async {
      await creations.settleAgent(creationId, error: error);
      return const DataAck();
    }(),
    WorktreeCleanupPreview() => cleanup.preview(),
    WorktreeCleanupSweep() => cleanup.sweep(automatic: false),
    WorktreeCleanupLogRead() => cleanup.log,
    ProjectFoldersCreate(
      :final projectName,
      :final root,
      :final gitUrl,
      :final workspaceId,
    ) =>
      folders.create(
        name: projectName,
        target:
            reach.environment(root.environmentId) ??
            (throw DataRefused.notFound(
              'no environment with id ${root.environmentId}',
            )),
        targetPath: root.path,
        gitUrl: gitUrl,
        workspaceId: workspaceId,
      ),
    ProjectRescan(:final projectId) => folders.rediscover(_project(projectId)),
    ScratchCheckoutCreate(:final environmentId, :final hint) =>
      folders.createScratchCheckout(
        target:
            reach.environment(environmentId) ??
            (throw DataRefused.notFound(
              'no environment with id $environmentId',
            )),
        hint: hint,
      ),
    final ProjectMove r => () {
      final project = _project(r.projectId);
      final environmentId = r.root?.environmentId ?? project.root.environmentId;
      return folders.update(
        project,
        target:
            reach.environment(environmentId) ??
            (throw DataRefused.notFound(
              'no environment with id $environmentId',
            )),
        name: r.projectName,
        root: r.root,
        defaultRepositoryId: r.defaultRepositoryId,
        clearDefaultRepository: r.clearDefaultRepository,
      );
    }(),
    final CheckoutRequest<Object?> r => _checkout(r),
  };

  Future<Object?> _checkout(
    CheckoutRequest<Object?> request,
  ) async => switch (request) {
    GitStatusOf() ||
    GitChangesOf() ||
    GitFileDiffStats() ||
    GitDiff() ||
    GitDiffUntracked() ||
    GitLog() ||
    GitBranch() ||
    GitHead() ||
    GitRevParse() ||
    GitAheadBehind() ||
    GitRemoteBranchesContaining() ||
    GitOriginFacts() ||
    GitMergeInProgress() ||
    GitBlobShas() ||
    GitDelivery() => checkouts.read(request),
    GitStage() ||
    GitUnstage() ||
    GitDiscard() ||
    GitCommitStaged() ||
    GitFetch() ||
    GitPull() ||
    GitPush() ||
    GitMerge() ||
    GitAbortMerge() ||
    GitMoveBranch() => checkouts.writeOf(request),
    WorktreesOf(:final checkout) => worktrees.list(checkouts.pathOf(checkout)),
    // Through the worktree service, not a plain read: which worktree has
    // each branch is half of the answer.
    GitBranches(:final checkout) => worktrees.branches(
      checkouts.pathOf(checkout),
    ),
    final WorktreeCreate r => creations.create(checkouts.pathOf(r.checkout), r),
    WorktreeRemove(:final checkout, :final worktree, :final force) => () async {
      final repo = checkouts.pathOf(checkout);
      try {
        final teardown = await worktrees.remove(repo, worktree, force: force);
        return teardown?.said;
      } finally {
        checkouts.touched(repo, CheckoutTouchCause.worktree);
      }
    }(),
    GitHubOverviewOf(:final checkout) => _overview(checkout),
    GitHubPullRequest(:final checkout, :final branch) => _pullRequest(
      checkout,
      branch,
    ),
    GitHubMarkReady(:final checkout, :final number) => () async {
      await checkouts
          .gitHubFor(checkout)
          .markPullRequestReady(checkouts.pathOf(checkout), number: number);
      return const DataAck();
    }(),
    GitHubCreatePr(:final checkout, :final title, :final body) =>
      checkouts
          .gitHubFor(checkout)
          .createPullRequest(
            checkouts.pathOf(checkout),
            title: title,
            body: body,
          ),
    GitHubRuns(:final checkout, :final branch, :final limit) =>
      checkouts
          .gitHubFor(checkout)
          .listWorkflowRuns(
            checkouts.pathOf(checkout),
            branch: branch,
            limit: limit.clamp(1, 50),
          ),
    GitHubRunLog(:final checkout, :final runId) =>
      checkouts
          .gitHubFor(checkout)
          .failedRunLog(checkouts.pathOf(checkout), runId: runId),
  };

  /// The three parts read side by side, each failing on its own: one `.wait`
  /// over all three turned a repository with issues switched off into a pane
  /// with nothing in it.
  Future<GitHubOverview> _overview(CheckoutRef checkout) async {
    final gh = checkouts.gitHubFor(checkout);
    final path = checkouts.pathOf(checkout);
    final (repository, pullRequests, issues) = await (
      _part(() => gh.getRepository(path)),
      _part(() => gh.listPullRequests(path)),
      _part(() => gh.listIssues(path)),
    ).wait;
    return GitHubOverview(
      repository: repository.value,
      pullRequests: pullRequests.value ?? const [],
      issues: issues.value ?? const [],
      repositoryFailure: repository.failure,
      pullRequestsFailure: pullRequests.failure,
      issuesFailure: issues.failure,
    );
  }

  static Future<({T? value, String? failure})> _part<T>(
    Future<T> Function() read,
  ) async {
    try {
      return (value: await read(), failure: null);
    } on GitHubException catch (e) {
      return (value: null, failure: e.message);
    } on Object catch (e) {
      return (value: null, failure: '$e');
    }
  }

  /// [branch]'s pull request, the repository's merge settings and review
  /// threads, and — only when a merge reads `BLOCKED` — the base's
  /// protection. A `gh` that could not tell reads as no pull request.
  Future<PullRequestReading> _pullRequest(
    CheckoutRef checkout,
    String branch,
  ) async {
    final gh = checkouts.gitHubFor(checkout);
    final path = checkouts.pathOf(checkout);
    final snapshot = await _orNull(
      () => gh.pullRequestFor(path, branch: branch),
    );
    if (snapshot == null || !snapshot.isOpen) {
      return PullRequestReading(pullRequest: snapshot);
    }
    final policy =
        await _orNull(() => gh.forgePolicyFor(path, number: snapshot.number)) ??
        kUnknownForgePolicy;
    final base = snapshot.baseRefName;
    final protection =
        snapshot.mergeStateStatus == MergeStateStatus.blocked && base != null
        ? await _orNull(() => gh.branchProtectionFor(path, branch: base)) ??
              BranchProtection.unknown
        : BranchProtection.unknown;
    return PullRequestReading(
      pullRequest: snapshot.withUnresolvedReviewThreads(
        policy.unresolvedReviewThreads,
      ),
      strategies: policy.strategies,
      protection: protection,
    );
  }

  Project _project(String id) =>
      _projects.getById(id) ?? (throw DataRefused.notFound('no project $id'));

  /// When Karmashala recorded making [worktree], by its setup record.
  DateTime? _createdAt(EnvironmentPath worktree) {
    for (final run in _setups.allRuns()) {
      if (run.environmentId == worktree.environmentId &&
          samePath(run.worktreePath, worktree.path)) {
        return run.ranAt;
      }
    }
    return null;
  }

  static Future<T?> _orNull<T>(Future<T?> Function() probe) async {
    try {
      return await probe();
    } on Object {
      return null;
    }
  }
}

final class _FunctionClock implements Clock {
  const _FunctionClock(this._now);

  final DateTime Function() _now;

  @override
  DateTime nowUtc() => _now().toUtc();
}
