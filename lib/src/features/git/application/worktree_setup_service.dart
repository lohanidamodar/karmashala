import 'dart:async';

import 'package:path/path.dart' as p;

import 'package:agent_cli/process.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_git/git.dart';

/// The checkout a worktree is being made of, and what it wants done. A callback
/// and not a DAO, so `git/` never resolves a path to a `repositories` row. Null
/// means the path is not a recorded checkout — nothing to do, not an error.
typedef WorktreeSetupLookup =
    ({String repositoryId, WorktreeSetup setup})? Function(
      EnvironmentPath repo,
    );

/// Where a setup command is asked to run.
class WorktreeSetupCommand {
  const WorktreeSetupCommand({
    required this.argv,
    required this.worktree,
    required this.environment,
    required this.title,
  });

  /// The command as argv, in the words of [environment].
  final List<String> argv;
  final EnvironmentPath worktree;
  final ExecutionEnvironment environment;

  /// What to label the pane — the worktree's folder name, so a fan-out of four
  /// setups is four distinguishable tabs.
  final String title;
}

/// Opens a **visible pane** on [command] and returns its pane id. Null means
/// there was nowhere visible, and the command is then not run at all: a setup
/// script whose output nobody can see is what this feature exists to remove.
typedef WorktreeSetupPaneOpener =
    String? Function(WorktreeSetupCommand command);

/// Files a finished report. See `WorktreeSetupDao.record`.
typedef WorktreeSetupRecorder = void Function(WorktreeSetupReport report);

/// Ends the process in a setup pane — a cancel reaching a script the agent was
/// waiting on.
typedef WorktreeSetupPaneCloser = void Function(String paneId);

/// Does to a new worktree what its repository asked: the gitignored copies,
/// then a pane on the setup command. Nothing throws; failures are recorded.
class WorktreeSetupService {
  WorktreeSetupService({
    required this.runnerFactory,
    required this.lookup,
    required this.record,
    this.openPane,
    this.closePane,
    Clock? clock,
  }) : clock = clock ?? const SystemClock();

  final CommandRunnerFactory runnerFactory;
  final WorktreeSetupLookup lookup;
  final WorktreeSetupRecorder record;

  /// Null in a container with no terminal; a configured command is then refused
  /// in words rather than run where nobody can see it.
  final WorktreeSetupPaneOpener? openPane;

  /// Null where panes cannot be ended from here; a cancel then says the script
  /// was left running.
  final WorktreeSetupPaneCloser? closePane;

  final Map<String, Completer<int?>> _exitWaiters = {};

  /// Exits heard before anybody waited on them — a script that ends at once.
  final Map<String, int?> _exitedUnwaited = {};

  final Clock clock;

  /// The reports whose command is still expected to be running, by pane id. In
  /// memory, because [noteExit] only ever sees panes this process opened.
  final Map<String, WorktreeSetupReport> _pending = {};

  /// Sets [worktree] up for [repo]. Returns the report, or null when there was
  /// nothing to do — a checkout nobody configured costs no process, stat or
  /// row, and this is on the path of every worktree the app makes.
  Future<WorktreeSetupReport?> run({
    required ExecutionEnvironment environment,
    required EnvironmentPath repo,
    required EnvironmentPath worktree,
  }) async {
    final found = lookup(repo);
    if (found == null || found.setup.isEmpty) return null;

    final runner = runnerFactory.forEnvironment(environment);
    final chosen = worktreeCopierFor(environment, runner);
    final copies = await _copy(
      setup: found.setup,
      git: GitService(runner),
      copier: chosen.copier,
      context: chosen.context,
      repo: repo,
      worktree: worktree,
    );

    final report = WorktreeSetupReport(
      repositoryId: found.repositoryId,
      worktreePath: worktree.path,
      environmentId: environment.id,
      ranAt: clock.nowUtc(),
      copies: copies,
      command: _startCommand(
        setup: found.setup,
        environment: environment,
        worktree: worktree,
      ),
    );
    _record(report);
    final pane = report.command?.paneId;
    if (pane != null && (report.command?.result.isPending ?? false)) {
      _pending[pane] = report;
    }
    return report;
  }

  /// The pane a setup command was running in has stopped. Returns the corrected
  /// report, or null when no setup was waiting on that pane — which is nearly
  /// every pane exit in the app, so this stays cheap and silent.
  WorktreeSetupReport? noteExit(String paneId, int? exitCode) {
    final pending = _pending.remove(paneId);
    final waiter = _exitWaiters.remove(paneId);
    if (pending == null) {
      if (waiter != null && !waiter.isCompleted) waiter.complete(exitCode);
      return null;
    }
    final corrected = pending.withCommand(pending.command?.afterExit(exitCode));
    _record(corrected);
    if (waiter == null) _exitedUnwaited[paneId] = exitCode;
    // After the record, so a creation waiting on this writes over it, not under.
    if (waiter != null && !waiter.isCompleted) waiter.complete(exitCode);
    return corrected;
  }

  /// Completes with the exit code of the setup command in [paneId] — null when
  /// it stopped without one — once [noteExit] hears of it.
  Future<int?> waitForExit(String paneId) {
    if (_exitedUnwaited.containsKey(paneId)) {
      return Future.value(_exitedUnwaited.remove(paneId));
    }
    return (_exitWaiters[paneId] ??= Completer<int?>()).future;
  }

  /// Stores [creation] on the newest report of [base]'s worktree — which a pane
  /// exit may have corrected since [base] was taken — and keeps the result as
  /// the one a later [noteExit] corrects, so neither write loses the other.
  WorktreeSetupReport saveCreation(
    WorktreeSetupReport base,
    WorktreeCreationRecord creation,
  ) {
    final latest = _latest[base.worktreePath] ?? base;
    final merged = latest.withCreation(creation).withCommand(latest.command);
    _record(merged);
    final pane = merged.command?.paneId;
    if (pane != null && _pending.containsKey(pane)) _pending[pane] = merged;
    return merged;
  }

  /// The newest report written for each worktree, by path.
  final Map<String, WorktreeSetupReport> _latest = {};

  void _record(WorktreeSetupReport report) {
    _latest[report.worktreePath] = report;
    record(report);
  }

  /// Ends the setup command in [paneId] and stops tracking it. False when there
  /// is no way to end a pane from here, and the command is still running.
  bool stopCommand(String paneId) {
    final closer = closePane;
    if (closer == null) return false;
    _pending.remove(paneId);
    _exitWaiters.remove(paneId);
    closer(paneId);
    return true;
  }

  /// The copy half: one `git check-ignore` for the whole list, then one copy per
  /// surviving path. Before the command, which usually *uses* what was copied,
  /// so a pane opened first would race it.
  Future<List<WorktreeCopyVerdict>> _copy({
    required WorktreeSetup setup,
    required GitService git,
    required WorktreeCopier copier,
    required p.Context context,
    required EnvironmentPath repo,
    required EnvironmentPath worktree,
  }) async {
    final verdicts = <WorktreeCopyVerdict>[];
    final candidates = <String>[];
    for (final path in setup.copyPaths) {
      final refusal = worktreeCopyPathRefusal(path);
      if (refusal != null) {
        verdicts.add(
          WorktreeCopyVerdict(
            path: path,
            result: WorktreeCopyResult.refusedPath,
            reason: refusal,
          ),
        );
        continue;
      }
      candidates.add(path.trim());
    }
    if (candidates.isEmpty) return verdicts;

    final ignored = await git.ignoredPaths(repo, candidates);
    for (final path in candidates) {
      // Null is git refusing the question, read as neither "tracked" nor
      // "ignored": copying on that is how a branch's files get overwritten.
      if (ignored == null) {
        verdicts.add(
          WorktreeCopyVerdict(
            path: path,
            result: WorktreeCopyResult.unknown,
            reason:
                'git could not be asked whether "$path" is ignored, so it was '
                'not copied. Nothing is copied on a reading Karmashala could '
                'not take.',
          ),
        );
        continue;
      }
      if (!ignored.contains(path)) {
        verdicts.add(
          WorktreeCopyVerdict(
            path: path,
            result: WorktreeCopyResult.refusedTracked,
            reason: '"$path" $worktreeCopyNotIgnored',
          ),
        );
        continue;
      }
      verdicts.add(
        await copier.copy(
          path: path,
          // Joined with the environment's own separator, never the host's; the
          // setting itself is always `/`-separated.
          source: context.joinAll([repo.path, ...path.split('/')]),
          destination: context.joinAll([worktree.path, ...path.split('/')]),
        ),
      );
    }
    return verdicts;
  }

  /// The command half: a pane, or a refusal saying why there is none. Started
  /// and not awaited, because a session launch is waiting on the caller.
  WorktreeCommandVerdict _startCommand({
    required WorktreeSetup setup,
    required ExecutionEnvironment environment,
    required EnvironmentPath worktree,
  }) {
    if (setup.command.isEmpty) {
      return const WorktreeCommandVerdict(
        result: WorktreeCommandResult.notConfigured,
        reason: 'No setup command is configured for this checkout.',
      );
    }
    final opener = openPane;
    if (opener == null) {
      return WorktreeCommandVerdict(
        result: WorktreeCommandResult.refusedNoPane,
        reason:
            'There is no terminal in this window to run the setup command in, '
            'so it was not run. Running it out of sight is the failure this '
            'setting exists to prevent — see CLAUDE.md §17 on what a bare '
            '`flutter` in the wrong shell does silently.',
        command: setup.command,
      );
    }
    final String? paneId;
    try {
      paneId = opener(
        WorktreeSetupCommand(
          argv: setup.command,
          worktree: worktree,
          environment: environment,
          title: 'Setup · ${lastPathSegment(worktree.path)}',
        ),
      );
    } on Object catch (error) {
      return WorktreeCommandVerdict(
        result: WorktreeCommandResult.couldNotStart,
        reason: 'The setup command could not be started: $error',
        command: setup.command,
      );
    }
    if (paneId == null) {
      return WorktreeCommandVerdict(
        result: WorktreeCommandResult.refusedNoPane,
        reason:
            'No pane could be opened for the setup command, so it was not '
            'run.',
        command: setup.command,
      );
    }
    return WorktreeCommandVerdict(
      result: WorktreeCommandResult.running,
      reason:
          'Running in its own pane. Nothing waits for it: its output is the '
          'report, and its exit code is recorded when the process stops.',
      command: setup.command,
      paneId: paneId,
    );
  }
}
