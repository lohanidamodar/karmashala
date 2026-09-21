import 'dart:async';

import 'package:agent_cli/process.dart';
import '../../environments/application/environment_resolver.dart';
import '../../environments/data/execution_environment_dao.dart';
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

/// High-level worktree lifecycle, resolving the correct runner for each
/// repository's environment. Where a session's per-session worktree choice
/// (ADR 0004) is realised; git remains the source of truth.
class WorktreeService {
  WorktreeService({
    required this.runnerFactory,
    required this.environmentDao,
    this.onCheckoutMoved,
    this.setup,
    this.creations,
    this.idleTimeout = const Duration(minutes: 5),
  });

  final CommandRunnerFactory runnerFactory;
  final ExecutionEnvironmentDao environmentDao;

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

  /// Where [repo]'s git runs, or the resolver's own refusal as a
  /// [GitException], in its words so this cannot drift from the launch paths.
  ExecutionEnvironment _environmentOf(EnvironmentPath repo) {
    final resolved = ExecutionEnvironmentResolver(
      environments: environmentDao,
      runners: runnerFactory,
    ).resolveFor(repo);
    final env = resolved.environment;
    if (env == null) throw GitException(resolved.reason);
    return env;
  }

  GitService _gitFor(EnvironmentPath repo) =>
      GitService(runnerFactory.forEnvironment(_environmentOf(repo)));

  /// Lists the worktrees of [repo].
  Future<List<GitWorktree>> list(EnvironmentPath repo) =>
      _gitFor(repo).listWorktrees(repo);

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
  Future<WorktreeCreated> create({
    required EnvironmentPath repo,
    required String worktreeName,
    required String branch,
    String? baseRef,
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
        baseRef: baseRef,
        launchesAgent: launchesAgent,
        tracker: t,
      ).run();
      return (worktree: worktree, tracker: t);
    } finally {
      creations?.remove(t);
    }
  }

  /// Removes the worktree at [worktree] of [repo].
  Future<void> remove(
    EnvironmentPath repo,
    EnvironmentPath worktree, {
    bool force = false,
  }) async {
    await _gitFor(repo).removeWorktree(repo, worktree, force: force);
    // Only after git actually removed it, or a still-correct listing would be
    // thrown away.
    onCheckoutMoved?.call(worktree);
  }
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
    required this.launchesAgent,
    required this.tracker,
  });

  final WorktreeService service;
  final ExecutionEnvironment env;
  final GitService git;
  final EnvironmentPath repo;
  final EnvironmentPath path;
  final String branch;
  final String? baseRef;
  final bool launchesAgent;
  final WorktreeCreationTracker tracker;

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
    return GitWorktree(path: path, branch: branch);
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
    final base = baseRef;
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
        detail: base == null
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
      await git.addWorktree(
        repo,
        worktreePath: path,
        branch: branch,
        baseRef: baseRef,
        checkout: false,
      );
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
    if (setup == null || configured == null || configured.isEmpty) {
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
