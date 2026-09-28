import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:karmashala_git/git.dart';
import 'worktree_creation_tracker.dart';
import 'worktree_setup_service.dart';

/// Notified with a directory whose *existence* has just changed. A fresh
/// worktree sits outside every root the OS watcher watches, so nothing else
/// would ever tell Quick Open's index its cached listing is now wrong.
typedef CheckoutMoved = void Function(EnvironmentPath directory);

/// A worktree git made, and the stage record of how it was made.
typedef WorktreeCreated = ({
  GitWorktree worktree,
  WorktreeCreationTracker tracker,
});

/// Where a repository's git commands run. Throws [GitException] in the words
/// of whoever resolves it — the app's resolver, or a session host that runs
/// only on its own machine — when that cannot be said.
typedef WorktreeEnvironmentOf =
    ExecutionEnvironment Function(EnvironmentPath repo);

/// High-level worktree lifecycle, resolving the correct runner for each
/// repository's environment. Where a session's per-session worktree choice
/// (ADR 0004) is realised; git remains the source of truth.
class WorktreeService {
  WorktreeService({
    required this.runnerFactory,
    required this.environmentOf,
    this.onCheckoutMoved,
    this.setup,
    this.creations,
    this.idleTimeout = const Duration(minutes: 5),
    this.teardownBound = const Duration(minutes: 5),
  });

  final CommandRunnerFactory runnerFactory;

  /// See [WorktreeEnvironmentOf].
  final WorktreeEnvironmentOf environmentOf;

  /// See [CheckoutMoved]. Null in a test that is only asserting git arguments.
  final CheckoutMoved? onCheckoutMoved;

  /// What a repository wants done to a worktree the moment git makes one. Null
  /// is no setup at all, never a silent one.
  final WorktreeSetupService? setup;

  /// Where a creation in flight is published so a surface can draw and cancel
  /// it. Null in a test with no surface.
  final WorktreeCreations? creations;

  /// How long a streamed git stage may print nothing before it is stopped.
  final Duration idleTimeout;

  /// How long a removal waits for the repository's teardown command.
  final Duration teardownBound;

  ExecutionEnvironment _environmentOf(EnvironmentPath repo) =>
      environmentOf(repo);

  GitService _gitFor(EnvironmentPath repo) =>
      GitService(runnerFactory.forEnvironment(_environmentOf(repo)));

  /// Git on [repo]'s own runner, for a reader that needs more than [list].
  GitService gitFor(EnvironmentPath repo) => _gitFor(repo);

  /// Lists the worktrees of [repo].
  Future<List<GitWorktree>> list(EnvironmentPath repo) =>
      _gitFor(repo).listWorktrees(repo);

  /// The branches of [repo], local and remote-tracking, each local one naming
  /// the worktree it is checked out in — what decides whether a new worktree
  /// can take it or only joining the one that has it can.
  Future<List<GitBranchRef>> branches(EnvironmentPath repo) async {
    final git = _gitFor(repo);
    final (refs, worktrees) = await (
      git.listBranches(repo),
      git.listWorktrees(repo),
    ).wait;
    final at = {
      for (final w in worktrees)
        if (w.branch != null && !w.isBare) w.branch!: w.path,
    };
    return [
      for (final ref in refs)
        ref.isRemote ? ref : ref.withWorktree(at[ref.name]),
    ];
  }

  /// Creates a worktree for [repo] on a new [branch], with no agent of its own.
  /// See [create].
  Future<GitWorktree> createForSession({
    required EnvironmentPath repo,
    required String worktreeName,
    required String branch,
    String? baseRef,
    WorktreeCreationTracker? tracker,
  }) async => (await create(
    repo: repo,
    worktreeName: worktreeName,
    branch: branch,
    baseRef: baseRef,
    tracker: tracker,
  )).worktree;

  /// Creates a worktree in named stages — fetch, checkout, submodules, setup
  /// script, agent — each through the repository's own [CommandRunner].
  ///
  /// With [launchesAgent] the agent stage is left running for the caller to
  /// settle through the tracker. Throws [WorktreeCreationCancelled] when the
  /// tracker is cancelled, and [GitException] when a stage the worktree cannot
  /// exist without fails; either way nothing half-made is left registered, or
  /// the tracker's record says what was left and why.
  ///
  /// With [existingBranch], [branch] names a branch that already exists and
  /// the worktree checks it out rather than creating one; [baseRef] is then
  /// ignored. A local branch is checked out as it is. A remote-tracking one
  /// (`origin/x`) with no local `x` gets a local `x` tracking it, which a
  /// failure removes again; one with a local `x` checks that out. A branch
  /// already checked out in another worktree is refused before git is asked
  /// to add anything: git allows it in one place only.
  Future<WorktreeCreated> create({
    required EnvironmentPath repo,
    required String worktreeName,
    required String branch,
    String? baseRef,
    bool existingBranch = false,
    bool launchesAgent = false,
    WorktreeCreationTracker? tracker,
  }) async {
    // Before any stage: a refusal here has made nothing.
    final env = _environmentOf(repo);
    final path = worktreePathFor(env.kind, repo, worktreeName);
    final t = tracker ?? WorktreeCreationTracker(repo: repo);
    creations?.add(t);
    try {
      final worktree = await _Creation(
        service: this,
        env: env,
        git: GitService(runnerFactory.forEnvironment(env)),
        repo: repo,
        path: path,
        branch: branch,
        baseRef: existingBranch ? null : baseRef,
        existingBranch: existingBranch,
        launchesAgent: launchesAgent,
        tracker: t,
      ).run();
      return (worktree: worktree, tracker: t);
    } finally {
      creations?.remove(t);
    }
  }

  /// Removes the worktree at [worktree] of [repo].
  Future<WorktreeTeardown?> remove(
    EnvironmentPath repo,
    EnvironmentPath worktree, {
    bool force = false,
  }) async {
    // The repository's own teardown first, while the directory still exists.
    final teardown = await setup?.teardown(
      environment: _environmentOf(repo),
      repo: repo,
      worktree: worktree,
      bound: teardownBound,
    );
    if (teardown != null && teardown.stillRunning) {
      throw GitException('${teardown.said} Nothing was removed.');
    }
    await _gitFor(repo).removeWorktree(repo, worktree, force: force);
    // Only after git actually removed it, or a still-correct listing would be
    // thrown away.
    onCheckoutMoved?.call(worktree);
    return teardown;
  }

  /// Removes [worktree] only if git agrees it is clean. No `force` parameter on
  /// purpose: automatic cleanup must have no way to discard anything, so git's
  /// own refusal of a dirty worktree is the last check, never an obstacle.
  Future<WorktreeTeardown?> removeIfClean(
    EnvironmentPath repo,
    EnvironmentPath worktree,
  ) => remove(repo, worktree);
}

/// One run of [WorktreeService.create]: the stages, in order, and what each
/// failure or cancel leaves behind.
class _Creation {
  _Creation({
    required this.service,
    required this.env,
    required this.git,
    required this.repo,
    required this.path,
    required this.branch,
    required this.baseRef,
    required this.existingBranch,
    required this.launchesAgent,
    required this.tracker,
  }) : _localBranch = branch,
       _makesBranch = !existingBranch;

  final WorktreeService service;
  final ExecutionEnvironment env;
  final GitService git;
  final EnvironmentPath repo;
  final EnvironmentPath path;
  final String branch;
  final String? baseRef;

  /// Whether [branch] already exists and is checked out, not created.
  final bool existingBranch;
  final bool launchesAgent;
  final WorktreeCreationTracker tracker;

  /// The local branch the worktree ends up on: [branch], or — for an
  /// existing remote-tracking `origin/x` — `x`.
  String _localBranch;

  /// Whether this creation makes [_localBranch], so a failure deletes it. Never
  /// for an existing local branch: that is somebody's work.
  bool _makesBranch;

  /// The remote-tracking branch a new local one is made to track.
  String? _trackRef;

  /// Whether git has registered the worktree, so a failure must remove it.
  bool _registered = false;

  /// The persisted row this creation writes, or null when there is nowhere to
  /// write one: no setup service, or a checkout no scan has recorded.
  WorktreeSetupReport? _row;

  WorktreeSetupService? get _setup => service.setup;

  void _stage(
    WorktreeStage stage,
    WorktreeStageState state, {
    String? detail,
    List<String>? tail,
  }) {
    final current = tracker.record.stage(stage);
    tracker.update(
      WorktreeStageStatus(
        stage: stage,
        state: state,
        detail: detail,
        percent: current.percent,
        progressLabel: current.progressLabel,
        outputTail: tail ?? const [],
      ),
    );
  }

  Future<GitWorktree> run() async {
    final found = _setup?.lookup(repo);
    if (found != null) {
      _row = WorktreeSetupReport(
        repositoryId: found.repositoryId,
        worktreePath: path.path,
        environmentId: env.id,
        ranAt: _setup!.clock.nowUtc(),
        copies: const [],
      );
    }

    await _fetch();
    await _checkout();
    await _submodules();
    await _setupScript(found?.setup);

    if (launchesAgent) {
      _stage(
        WorktreeStage.agent,
        WorktreeStageState.running,
        detail: 'Starting the agent in the worktree.',
      );
      tracker.onSettled = _persist;
    } else {
      _stage(
        WorktreeStage.agent,
        WorktreeStageState.skipped,
        detail: 'This creation starts no agent of its own.',
      );
      tracker.finish(tracker.record.settledOutcome);
    }
    _persist(tracker.record);

    // After the setup: an index invalidated before the copies land would be
    // re-warmed on a directory that was still filling up.
    service.onCheckoutMoved?.call(path);
    return GitWorktree(path: path, branch: _localBranch);
  }

  void _persist(WorktreeCreationRecord record) {
    final row = _row;
    final setup = _setup;
    if (row == null || setup == null) return;
    _row = setup.saveCreation(row, record);
  }

  /// A stream through [GitService.streamGit] whose percentages and tail land on
  /// [stage] as they arrive.
  Future<GitStreamResult> _stream(
    WorktreeStage stage,
    EnvironmentPath directory,
    List<String> args,
  ) => git.streamGit(
    directory,
    args,
    cancel: tracker.cancelled,
    idleTimeout: service.idleTimeout,
    onLine: (line) {
      final progress = parseGitProgress(line);
      if (progress == null) return;
      tracker.update(
        tracker.record
            .stage(stage)
            .copyWith(percent: progress.percent, progressLabel: progress.label),
      );
    },
  );

  // --- fetch ---------------------------------------------------------------

  Future<void> _fetch() async {
    await _stopIfCancelled(WorktreeStage.fetch);
    // An existing branch is fetched when it names a remote's, so a worktree on
    // `origin/x` starts from what the remote has now.
    final base = existingBranch ? branch : baseRef;
    final slash = base?.indexOf('/') ?? -1;
    String? remote;
    if (base != null && slash > 0) {
      final candidate = base.substring(0, slash);
      final remotes = await git.remoteNames(repo);
      if (remotes.contains(candidate)) remote = candidate;
    }
    if (remote == null) {
      _stage(
        WorktreeStage.fetch,
        WorktreeStageState.skipped,
        detail: existingBranch
            ? 'Checking out $branch as it is here, so there is nothing to '
                  'fetch.'
            : base == null
            ? 'Branching from the checkout\'s own HEAD, so there is nothing '
                  'to fetch.'
            : '"$base" does not name a remote branch, so there is nothing to '
                  'fetch.',
      );
      return;
    }
    final remoteBranch = base!.substring(slash + 1);
    _stage(
      WorktreeStage.fetch,
      WorktreeStageState.running,
      detail: 'Fetching $remoteBranch from $remote.',
    );
    final GitStreamResult result;
    try {
      result = await _stream(WorktreeStage.fetch, repo, [
        'fetch',
        '--progress',
        remote,
        remoteBranch,
      ]);
    } on GitCancelled catch (cancel) {
      await _cancelled(WorktreeStage.fetch, cancel.outputTail);
    } on CommandException catch (error) {
      _stage(
        WorktreeStage.fetch,
        WorktreeStageState.warning,
        detail:
            'git fetch could not be started ($error). Branching from what is '
            'already local.',
      );
      return;
    }
    if (result.ok) {
      _stage(WorktreeStage.fetch, WorktreeStageState.done);
      return;
    }
    // A fetch that failed still leaves the last fetched copy to branch from;
    // if there is none, the checkout says so in git's words.
    _stage(
      WorktreeStage.fetch,
      WorktreeStageState.warning,
      detail: result.stalled
          ? 'git fetch printed nothing for ${_minutes(service.idleTimeout)} '
                'and was stopped. Branching from what is already local.'
          : 'git fetch exited ${result.exitCode}. Branching from what is '
                'already local.',
      tail: result.outputTail,
    );
  }

  // --- checkout ------------------------------------------------------------

  Future<void> _checkout() async {
    await _stopIfCancelled(WorktreeStage.checkout);
    _stage(
      WorktreeStage.checkout,
      WorktreeStageState.running,
      detail: 'Registering the worktree with git.',
    );
    try {
      if (existingBranch) {
        await _resolveExisting();
        if (_makesBranch) {
          // A new local branch on the remote's, tracking it (git's default
          // for a remote-tracking start point).
          await git.addWorktree(
            repo,
            worktreePath: path,
            branch: _localBranch,
            baseRef: _trackRef,
            checkout: false,
          );
        } else {
          await git.addWorktreeOnBranch(
            repo,
            worktreePath: path,
            branch: _localBranch,
            checkout: false,
          );
        }
      } else {
        await git.addWorktree(
          repo,
          worktreePath: path,
          branch: branch,
          baseRef: baseRef,
          checkout: false,
        );
      }
    } on Object catch (error) {
      // Nothing was registered: git refused before writing, in its own words.
      _stage(
        WorktreeStage.checkout,
        WorktreeStageState.failed,
        detail: error is GitException ? error.message : '$error',
      );
      _fail(cleanup: null);
      rethrow;
    }
    _registered = true;

    _stage(
      WorktreeStage.checkout,
      WorktreeStageState.running,
      detail: 'Writing the branch\'s files.',
    );
    final GitStreamResult result;
    try {
      result = await _stream(WorktreeStage.checkout, path, [
        'checkout',
        '--progress',
      ]);
    } on GitCancelled catch (cancel) {
      await _cancelled(WorktreeStage.checkout, cancel.outputTail);
    } on CommandException catch (error) {
      await _failed(
        WorktreeStage.checkout,
        'git checkout could not be started: $error',
        const [],
      );
    }
    if (!result.ok) {
      await _failed(
        WorktreeStage.checkout,
        result.stalled
            ? 'git checkout printed nothing for '
                  '${_minutes(service.idleTimeout)} and was stopped.'
            : 'git checkout exited ${result.exitCode}.',
        result.outputTail,
      );
    }
    _stage(WorktreeStage.checkout, WorktreeStageState.done);
  }

  /// Settles which local branch an existing-branch creation checks out, and
  /// refuses one another worktree has — in words that say where, rather than
  /// git's "already used by worktree".
  Future<void> _resolveExisting() async {
    String? local;
    if (await git.revParse(repo, 'refs/heads/$branch') != null) {
      local = branch;
    } else {
      final slash = branch.indexOf('/');
      if (slash > 0 &&
          await git.revParse(repo, 'refs/remotes/$branch') != null) {
        local = branch.substring(slash + 1);
        if (await git.revParse(repo, 'refs/heads/$local') == null) {
          _trackRef = branch;
          _makesBranch = true;
        }
      }
    }
    if (local == null) {
      throw GitException('"$branch" is not a branch of this repository.');
    }
    _localBranch = local;
    if (_makesBranch) return;
    for (final w in await git.listWorktrees(repo)) {
      if (w.branch == local) {
        throw GitException(
          '$local is already checked out at ${w.path.path}, and git lets a '
          'branch be checked out in one place only. Join that worktree '
          'instead, or pick another branch.',
        );
      }
    }
  }

  // --- submodules ----------------------------------------------------------

  Future<void> _submodules() async {
    await _stopIfCancelled(WorktreeStage.submodules);
    final bool declared;
    try {
      declared = await git.hasSubmodules(path);
    } on CommandException catch (error) {
      _stage(
        WorktreeStage.submodules,
        WorktreeStageState.warning,
        detail: 'Could not ask git whether this branch has submodules: $error',
      );
      return;
    }
    if (!declared) {
      _stage(
        WorktreeStage.submodules,
        WorktreeStageState.skipped,
        detail: 'This branch declares no submodules.',
      );
      return;
    }
    _stage(
      WorktreeStage.submodules,
      WorktreeStageState.running,
      detail: 'Updating submodules.',
    );
    final GitStreamResult result;
    try {
      result = await _stream(WorktreeStage.submodules, path, [
        'submodule',
        'update',
        '--init',
        '--recursive',
        '--progress',
      ]);
    } on GitCancelled catch (cancel) {
      await _cancelled(WorktreeStage.submodules, cancel.outputTail);
    } on CommandException catch (error) {
      _stage(
        WorktreeStage.submodules,
        WorktreeStageState.warning,
        detail: 'git submodule could not be started: $error',
      );
      return;
    }
    if (result.ok) {
      _stage(WorktreeStage.submodules, WorktreeStageState.done);
      return;
    }
    // Kept rather than rolled back: the worktree is usable without them, and
    // `git submodule update` can be re-run in it.
    _stage(
      WorktreeStage.submodules,
      WorktreeStageState.warning,
      detail: result.stalled
          ? 'git submodule update printed nothing for '
                '${_minutes(service.idleTimeout)} and was stopped. The '
                'worktree is kept; run it again inside it.'
          : 'git submodule update exited ${result.exitCode}. The worktree is '
                'kept; run it again inside it.',
      tail: result.outputTail,
    );
  }

  // --- setup script --------------------------------------------------------

  Future<void> _setupScript(WorktreeSetup? configured) async {
    await _stopIfCancelled(WorktreeStage.setupScript);
    final setup = _setup;
    if (setup == null ||
        configured == null ||
        (configured.command.isEmpty && configured.copyPaths.isEmpty)) {
      _stage(
        WorktreeStage.setupScript,
        WorktreeStageState.skipped,
        detail: 'No worktree setup is configured for this checkout.',
      );
      return;
    }
    _stage(
      WorktreeStage.setupScript,
      WorktreeStageState.running,
      detail: configured.copyPaths.isEmpty
          ? 'Starting the setup command.'
          : 'Copying ignored paths in.',
    );
    final WorktreeSetupReport? report;
    try {
      report = await setup.run(environment: env, repo: repo, worktree: path);
    } on Object catch (error) {
      // Kept: git has made a whole worktree, and a setup is cheap to re-run.
      _stage(
        WorktreeStage.setupScript,
        WorktreeStageState.warning,
        detail: 'The setup could not be run: $error',
      );
      return;
    }
    if (report == null) {
      _stage(WorktreeStage.setupScript, WorktreeStageState.skipped);
      return;
    }
    _row = report;
    final copyProblems = [
      for (final copy in report.problems) '${copy.path}: ${copy.reason}',
    ];
    final command = report.command;
    if (command == null || !command.result.isPending) {
      final commandProblem = command != null && command.result.needsAttention;
      _stage(
        WorktreeStage.setupScript,
        copyProblems.isEmpty && !commandProblem
            ? WorktreeStageState.done
            : WorktreeStageState.warning,
        detail: [...copyProblems, ?command?.reason].join(' '),
      );
      return;
    }

    final pane = command.paneId!;
    final waits = launchesAgent && !configured.startAgentBeforeSetup;
    _stage(
      WorktreeStage.setupScript,
      WorktreeStageState.running,
      detail: [
        ...copyProblems,
        waits
            ? 'Running in its own pane; the agent waits for it to finish.'
            : 'Running in its own pane; nothing waits for it.',
      ].join(' '),
    );
    if (!waits) return;

    final exited = await Future.any<({bool cancelled, int? code})>([
      setup.waitForExit(pane).then((code) => (cancelled: false, code: code)),
      tracker.cancelled.then((_) => (cancelled: true, code: null)),
    ]);
    if (exited.cancelled) {
      final stopped = setup.stopCommand(pane);
      await _cancelled(
        WorktreeStage.setupScript,
        const [],
        note: stopped
            ? 'The setup command\'s pane was ended.'
            : 'The setup command is still running in its pane — there was no '
                  'way to end it from here.',
      );
    }
    final after = command.afterExit(exited.code);
    _stage(
      WorktreeStage.setupScript,
      after.result == WorktreeCommandResult.succeeded
          ? (copyProblems.isEmpty
                ? WorktreeStageState.done
                : WorktreeStageState.warning)
          : WorktreeStageState.failed,
      // The agent still starts: the worktree is whole, and a setup script is
      // cheap to re-run where a checkout is not.
      detail: [...copyProblems, after.reason].join(' '),
    );
  }

  // --- ending --------------------------------------------------------------

  Future<void> _stopIfCancelled(WorktreeStage stage) async {
    if (tracker.isCancelled) await _cancelled(stage, const []);
  }

  /// Marks [stage] stopped, undoes what git registered, and throws.
  Future<Never> _cancelled(
    WorktreeStage stage,
    List<String> tail, {
    String? note,
  }) async {
    _stage(
      stage,
      WorktreeStageState.failed,
      detail: 'Cancelled while running.',
      tail: tail,
    );
    final cleanup = [?note, await _cleanUp()].join(' ');
    tracker.replace(
      tracker.record
          .skipPending('Not run: the creation was cancelled.')
          .finish(WorktreeCreationOutcome.cancelled, cleanup: cleanup),
    );
    _persist(tracker.record);
    throw WorktreeCreationCancelled(cleanup);
  }

  /// Marks [stage] failed with its output tail, undoes what git registered,
  /// and throws git's words.
  Future<Never> _failed(
    WorktreeStage stage,
    String why,
    List<String> tail,
  ) async {
    _stage(stage, WorktreeStageState.failed, detail: why, tail: tail);
    final cleanup = await _cleanUp();
    _fail(cleanup: cleanup);
    final last = tail.isEmpty ? '' : ' ${tail.last}';
    throw GitException('$why$last $cleanup');
  }

  void _fail({required String? cleanup}) {
    tracker.replace(
      tracker.record
          .skipPending('Not run: an earlier stage failed.')
          .finish(WorktreeCreationOutcome.failed, cleanup: cleanup),
    );
    _persist(tracker.record);
  }

  /// Removes the worktree and the branch this creation made. Returns what was
  /// done — or, plainly, what was left and why.
  Future<String> _cleanUp() async {
    if (!_registered) return 'Nothing had been created yet.';
    final left = <String>[];
    try {
      await git.removeWorktree(repo, path, force: true);
    } on Object catch (error) {
      left.add('the worktree at ${path.path} (${_words(error)})');
    }
    try {
      // Forgets the registration when the folder went but the entry did not.
      await git.pruneWorktrees(repo);
    } on Object {
      // The removal above is what is reported; a prune that fails leaves
      // nothing that removal did not already name.
    }
    final branch = _localBranch;
    if (!_makesBranch) {
      // An existing branch is not this creation's to delete.
      service.onCheckoutMoved?.call(path);
      return left.isEmpty
          ? 'Removed the half-made worktree at ${path.path}; the branch '
                '$branch is kept.'
          : 'Could not remove ${left.join(', or ')}. Remove it with '
                '`git worktree remove --force ${path.path}`.';
    }
    // Only once the worktree is gone: git will not delete a checked-out branch.
    if (left.isEmpty) {
      try {
        await git.deleteBranch(repo, branch);
      } on Object catch (error) {
        left.add('the branch $branch (${_words(error)})');
      }
    } else {
      left.add(
        'the branch $branch, which git will not delete while it is '
        'checked out there',
      );
    }
    service.onCheckoutMoved?.call(path);
    if (left.isEmpty) {
      return 'Removed the half-made worktree at ${path.path} and its branch '
          '$branch.';
    }
    return 'Could not remove ${left.join(', or ')}. Remove it with '
        '`git worktree remove --force ${path.path}` and '
        '`git branch -D $branch`.';
  }

  static String _words(Object error) =>
      error is GitException ? error.message : '$error';

  static String _minutes(Duration d) => d.inMinutes >= 1
      ? '${d.inMinutes} minute${d.inMinutes == 1 ? '' : 's'}'
      : '${d.inSeconds} seconds';
}
