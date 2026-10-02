import 'dart:async';
import 'dart:math' as math;

import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/cleanup.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_git/github.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_git/worktrees.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';

/// **Git, worktrees and GitHub, asked of the server** (slice 3b): every read
/// and write of a checkout runs where the checkout lives, at the server, and
/// what it moved comes back as a change ([touches]) — nothing here spawns a
/// process or reads a `.git`. A refusal comes back as the trouble it was:
/// [NotAGitRepository], [CommandException] for an environment that did not
/// answer, [GitException] (or [GitHubException]) in git's own words.
class GitData {
  GitData(this._client) {
    _changes = _client.gitChanges.listen(_changed);
  }

  final DataClient _client;
  late final StreamSubscription<GitChange> _changes;
  final _touches = StreamController<CheckoutTouched>.broadcast(sync: true);
  final _cleanups = StreamController<WorktreeCleanupLog>.broadcast(sync: true);

  /// The creations this client started, by id, followed as they move.
  final Map<String, WorktreeCreationTracker> _creations = {};

  /// Checkouts that may read differently now, from any client's write, a
  /// worktree made or removed, or an agent's turn ending there.
  Stream<CheckoutTouched> get touches => _touches.stream;

  /// Worktree cleanup's log and last sweep, each time a sweep ends.
  Stream<WorktreeCleanupLog> get cleanups => _cleanups.stream;

  void _changed(GitChange change) {
    switch (change) {
      case final CheckoutTouched touched:
        if (!_touches.isClosed) _touches.add(touched);
      case WorktreeCreationChanged(:final creationId, :final record):
        _creations[creationId]?.replace(record);
      case WorktreeCleanupChanged(:final log):
        if (!_cleanups.isClosed) _cleanups.add(log);
    }
  }

  Future<void> dispose() async {
    await _changes.cancel();
    await _touches.close();
    await _cleanups.close();
  }

  Future<R> _ask<R>(GitWorkRequest<R> request) async {
    try {
      return (await _client.send(request)).value;
    } on DataRefused catch (refusal) {
      throw _troubleOf(request, refusal);
    }
  }

  static Object _troubleOf(GitWorkRequest<Object?> request, DataRefused r) {
    final directory = request is CheckoutRequest<Object?>
        ? request.checkout.directory
        : null;
    final github = switch (request) {
      GitHubOverviewOf() ||
      GitHubPullRequest() ||
      GitHubMarkReady() ||
      GitHubCreatePr() ||
      GitHubRuns() ||
      GitHubRunLog() => true,
      _ => false,
    };
    final folders = switch (request) {
      ProjectFoldersCreate() ||
      ProjectRescan() ||
      ProjectMove() ||
      ScratchCheckoutCreate() => true,
      _ => false,
    };
    return switch (r.code) {
      DataRefusalCode.notFound
          when directory != null &&
              r.message.endsWith('is not a git repository') =>
        NotAGitRepository(directory),
      DataRefusalCode.unavailable => CommandException(r.message),
      _ when github => GitHubException(r.message),
      _ when folders => RepositoryDiscoveryException(r.message),
      _ => GitException(r.message),
    };
  }

  static CheckoutRef _at(EnvironmentPath path) => CheckoutRef.at(path);

  // Reads.

  /// The branch, its upstream, their divergence and the changed files.
  Future<WorkingTreeStatus> statusWithBranch(EnvironmentPath repo) =>
      _ask(GitStatusOf(_at(repo)));

  Future<List<FileChange>> changes(EnvironmentPath repo) =>
      _ask(GitChangesOf(_at(repo)));

  Future<Map<String, FileDiffStat>> fileDiffStats(EnvironmentPath repo) =>
      _ask(GitFileDiffStats(_at(repo)));

  Future<String> diff(
    EnvironmentPath repo, {
    String? path,
    bool staged = false,
    String? base,
  }) => _ask(GitDiff(_at(repo), path: path, staged: staged, base: base));

  /// One file's diff: a plain one, or — when that is empty and git does not
  /// track the file — the untracked file drawn as all added.
  Future<String> diffForFile(
    EnvironmentPath repo,
    String path, {
    String? base,
  }) async {
    final patch = await diff(repo, path: path, base: base);
    if (patch.isNotEmpty) return patch;
    return _ask(GitDiffUntracked(_at(repo), path));
  }

  Future<List<GitCommit>> log(EnvironmentPath repo, {int limit = 20}) =>
      _ask(GitLog(_at(repo), limit: limit));

  /// The branch checked out; null when detached.
  Future<String?> currentBranch(EnvironmentPath repo) =>
      _ask(GitBranch(_at(repo)));

  /// What [repo]'s `HEAD` file names — branch, or a short sha — read at the
  /// server without git; null for a checkout off its own filesystem.
  Future<String?> head(EnvironmentPath repo) => _ask(GitHead(_at(repo)));

  Future<String?> revParse(EnvironmentPath repo, String rev) =>
      _ask(GitRevParse(_at(repo), rev));

  Future<AheadBehind?> aheadBehind(
    EnvironmentPath repo, {
    required String base,
  }) => _ask(GitAheadBehind(_at(repo), base: base));

  /// Commits on [repo]'s branch that [base] does not have; null when git
  /// could not say.
  Future<int?> commitsAhead(
    EnvironmentPath repo, {
    required String base,
  }) async => (await aheadBehind(repo, base: base))?.ahead;

  Future<List<String>?> remoteBranchesContaining(
    EnvironmentPath repo,
    String rev,
  ) => _ask(GitRemoteBranchesContaining(_at(repo), rev));

  Future<RepositoryOrigin> originFacts(EnvironmentPath repo) =>
      _ask(GitOriginFacts(_at(repo)));

  /// `origin`'s URL, or null when there is none.
  Future<String?> remoteUrl(EnvironmentPath repo) async =>
      (await originFacts(repo)).url;

  Future<bool?> mergeInProgress(EnvironmentPath repo) =>
      _ask(GitMergeInProgress(_at(repo)));

  /// The content fingerprint of each of [paths]; one git could not hash is
  /// absent.
  Future<Map<String, String>> blobShas(
    EnvironmentPath repo,
    List<String> paths,
  ) => _ask(GitBlobShas(_at(repo), paths));

  final Map<EnvironmentPath, Completer<GitPresence>> _presenceAsked = {};

  /// Whether [checkout] is under git, from the filesystem at the server.
  /// Every row that asks in one turn of the event loop is one request.
  Future<GitPresence> presenceOf(EnvironmentPath checkout) {
    final asked = _presenceAsked[checkout];
    if (asked != null) return asked.future;
    final waiting = Completer<GitPresence>();
    _presenceAsked[checkout] = waiting;
    if (_presenceAsked.length == 1) scheduleMicrotask(_askPresence);
    return waiting.future;
  }

  Future<void> _askPresence() async {
    final batch = Map.of(_presenceAsked);
    _presenceAsked.clear();
    final checkouts = batch.keys.toList();
    try {
      final answers = await _ask(GitPresenceOf(checkouts));
      for (final (index, checkout) in checkouts.indexed) {
        batch[checkout]!.complete(
          index < answers.length ? answers[index] : GitPresence.unknown,
        );
      }
    } on Object {
      // No server is not a statement about a folder.
      for (final waiting in batch.values) {
        waiting.complete(GitPresence.unknown);
      }
    }
  }

  /// The local half of [directory]'s delivery; a worktree names the
  /// [repository] it came from.
  Future<SessionDelivery> delivery(
    EnvironmentPath directory, {
    EnvironmentPath? repository,
  }) => _ask(GitDelivery(_at(directory), repository: repository));

  // Writes. Each is told back as a touch of the checkout.

  /// Stages [paths], or everything when none are named.
  Future<void> stage(EnvironmentPath repo, {List<String> paths = const []}) =>
      _ask(GitStage(_at(repo), paths));

  Future<void> unstage(EnvironmentPath repo, List<String> paths) =>
      _ask(GitUnstage(_at(repo), paths));

  /// Rewinds [tracked] paths and deletes [untracked] ones.
  Future<void> discard(
    EnvironmentPath repo, {
    List<String> tracked = const [],
    List<String> untracked = const [],
  }) => _ask(GitDiscard(_at(repo), tracked: tracked, untracked: untracked));

  Future<void> commit(
    EnvironmentPath repo,
    String message, {
    bool all = false,
  }) => _ask(GitCommitStaged(_at(repo), message, all: all));

  Future<void> fetch(EnvironmentPath repo) => _ask(GitFetch(_at(repo)));

  Future<void> pull(
    EnvironmentPath repo, {
    bool rebase = false,
    bool merge = false,
  }) => _ask(GitPull(_at(repo), rebase: rebase, merge: merge));

  /// Pushes after the server's secret scan; answers how the scan went.
  Future<String> push(EnvironmentPath repo, {String? remote, String? branch}) =>
      _ask(GitPush(_at(repo), remote: remote, branch: branch));

  /// Merges [branch], always with a merge commit.
  Future<void> mergeBranch(EnvironmentPath repo, String branch) =>
      _ask(GitMerge(_at(repo), branch, commit: true));

  /// Brings the branch level with [ref], fast-forwarding when it can.
  Future<void> mergeRef(EnvironmentPath repo, String ref) =>
      _ask(GitMerge(_at(repo), ref));

  Future<bool> abortMerge(EnvironmentPath repo) =>
      _ask(GitAbortMerge(_at(repo)));

  Future<void> moveBranchTo(
    EnvironmentPath repo, {
    required String branch,
    required String sha,
  }) => _ask(GitMoveBranch(_at(repo), branch: branch, sha: sha));

  // Worktrees.

  /// The worktrees of [repo], the main one first.
  Future<List<GitWorktree>> worktreesOf(EnvironmentPath repo) =>
      _ask(WorktreesOf(_at(repo)));

  /// Every local and remote-tracking branch of [repo], the most recently
  /// committed to first, each local one naming the worktree it is out in.
  Future<List<GitBranchRef>> branchesOf(EnvironmentPath repo) =>
      _ask(GitBranches(_at(repo)));

  /// Worktree-or-not, branch and owner of recorded checkouts [ids].
  Future<Map<String, CheckoutLabel>> labels(List<String> ids) =>
      _ask(WorktreeLabels(ids));

  final _random = math.Random();

  /// Asks the server to make a worktree, following its stages on [tracker]
  /// (one of its own when null) and cancelling it when the tracker is.
  Future<WorktreeCreated> createWorktree({
    required EnvironmentPath repo,
    required String worktreeName,
    required String branch,
    String? baseRef,
    bool launchesAgent = false,
    WorktreeCreationTracker? tracker,
    WorktreeCreations? creations,
  }) async {
    final id =
        '${DateTime.now().microsecondsSinceEpoch}-'
        '${_random.nextInt(1 << 32).toRadixString(16)}';
    final t = tracker ?? WorktreeCreationTracker(repo: repo);
    _creations[id] = t;
    creations?.add(t);
    unawaited(
      t.cancelled.then(
        (_) => _client
            .send(WorktreeCreationCancel(id))
            .then<void>((_) {}, onError: (Object _) {}),
      ),
    );
    try {
      final created = await _ask(
        WorktreeCreate(
          _at(repo),
          creationId: id,
          worktreeName: worktreeName,
          branch: branch,
          baseRef: baseRef,
          launchesAgent: launchesAgent,
        ),
      );
      t.replace(created.record);
      if (launchesAgent) {
        t.onSettled = (_) {
          final agent = t.record.stage(WorktreeStage.agent);
          unawaited(
            _client
                .send(
                  WorktreeAgentSettled(
                    id,
                    error: agent.state == WorktreeStageState.failed
                        ? agent.detail
                        : null,
                  ),
                )
                .then<void>((_) {}, onError: (Object _) {}),
          );
          _creations.remove(id);
        };
      } else {
        _creations.remove(id);
      }
      return (worktree: created.worktree, tracker: t);
    } on GitException catch (error) {
      _creations.remove(id);
      if (t.isCancelled) {
        throw WorktreeCreationCancelled(
          error.message.replaceFirst('Worktree creation cancelled. ', ''),
        );
      }
      rethrow;
    } catch (_) {
      _creations.remove(id);
      rethrow;
    } finally {
      creations?.remove(t);
    }
  }

  /// Removes [worktree] of [repo] — its teardown first. [force] only for a
  /// removal a person confirmed over uncommitted changes. Answers what the
  /// teardown said.
  Future<String?> removeWorktree(
    EnvironmentPath repo,
    EnvironmentPath worktree, {
    bool force = false,
  }) => _ask(WorktreeRemove(_at(repo), worktree: worktree, force: force));

  // Worktree cleanup.

  Future<WorktreeCleanupReport> previewCleanup() =>
      _ask(const WorktreeCleanupPreview());

  Future<WorktreeCleanupReport> sweepCleanup() =>
      _ask(const WorktreeCleanupSweep());

  Future<WorktreeCleanupLog> cleanupLog() =>
      _ask(const WorktreeCleanupLogRead());

  // A project's folders.

  /// Creates project [name] at [root] — cloning [gitUrl] first when given —
  /// with a checkout for each repository under it.
  Future<ProjectCheckouts> createProject({
    required String name,
    required EnvironmentPath root,
    String? gitUrl,
    String? workspaceId,
  }) => _ask(
    ProjectFoldersCreate(
      projectName: name,
      root: root,
      gitUrl: gitUrl,
      workspaceId: workspaceId,
    ),
  );

  /// Scans [projectId]'s root again; answers the checkouts it added.
  Future<List<Repository>> rescanProject(String projectId) =>
      _ask(ProjectRescan(projectId));

  /// A folder of its own for a session without a project, under
  /// [environmentId]'s Scratch project; [hint] names it.
  Future<Repository> createScratchCheckout(
    String environmentId, {
    String? hint,
  }) => _ask(ScratchCheckoutCreate(environmentId: environmentId, hint: hint));

  /// Edits a project whose moved root must be scanned first.
  Future<ProjectUpdated> moveProject(
    String projectId, {
    String? name,
    EnvironmentPath? root,
    String? defaultRepositoryId,
    bool clearDefaultRepository = false,
  }) => _ask(
    ProjectMove(
      projectId,
      projectName: name,
      root: root,
      defaultRepositoryId: defaultRepositoryId,
      clearDefaultRepository: clearDefaultRepository,
    ),
  );

  // GitHub.

  Future<GitHubOverview> gitHubOverview(EnvironmentPath repo) =>
      _ask(GitHubOverviewOf(_at(repo)));

  Future<PullRequestReading> pullRequest(
    EnvironmentPath repo, {
    required String branch,
  }) => _ask(GitHubPullRequest(_at(repo), branch: branch));

  Future<void> markPullRequestReady(
    EnvironmentPath repo, {
    required int number,
  }) => _ask(GitHubMarkReady(_at(repo), number: number));

  Future<String> createPullRequest(
    EnvironmentPath repo, {
    required String title,
    String body = '',
  }) => _ask(GitHubCreatePr(_at(repo), title: title, body: body));

  Future<List<WorkflowRun>> workflowRuns(
    EnvironmentPath repo, {
    String? branch,
  }) => _ask(GitHubRuns(_at(repo), branch: branch));

  Future<WorkflowRunLog> failedRunLog(
    EnvironmentPath repo, {
    required int runId,
  }) => _ask(GitHubRunLog(_at(repo), runId: runId));
}

final gitDataProvider = Provider<GitData>((ref) {
  final data = GitData(ref.watch(dataClientProvider));
  ref.onDispose(() => unawaited(data.dispose()));
  return data;
});

/// How many times each checkout was touched since this app started — what a
/// reading of a checkout watches (its own entry), so a write, a worktree or a
/// turn ending there reads it again, and nothing polls.
class CheckoutTouches extends Notifier<Map<Checkout, int>> {
  @override
  Map<Checkout, int> build() {
    final subscription = ref.watch(gitDataProvider).touches.listen((touched) {
      final checkout = Checkout(touched.directory);
      state = {...state, checkout: (state[checkout] ?? 0) + 1};
    });
    ref.onDispose(subscription.cancel);
    return const {};
  }
}

final checkoutTouchesProvider =
    NotifierProvider<CheckoutTouches, Map<Checkout, int>>(CheckoutTouches.new);

/// Watches [path]'s touches from a provider that reads it.
extension CheckoutTouchWatch on Ref {
  void watchCheckout(EnvironmentPath path) {
    final key = Checkout(path);
    watch(checkoutTouchesProvider.select((touches) => touches[key] ?? 0));
  }
}
