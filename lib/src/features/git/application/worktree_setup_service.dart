import 'package:path/path.dart' as p;

import '../../../core/process/command_runner_factory.dart';
import 'package:karmashala_core/util.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/execution_environment.dart';
import '../data/git_service.dart';
import '../data/worktree_copier.dart';
import '../domain/git_worktree.dart';
import '../domain/worktree_setup.dart';

/// The checkout a worktree is being made of, and what it wants done.
///
/// A callback rather than a DAO, for the reason `CheckoutMoved` gives above it:
/// `git/` has no business resolving a path to a `repositories` row, and a
/// service composed for a test that only asserts git arguments must not need a
/// database. Null means the path is not a recorded checkout — which is not an
/// error, only nothing to do.
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

  /// What to label the pane. The worktree's folder name, so a fan-out of four
  /// setups is four distinguishable tabs.
  final String title;
}

/// Opens a **visible pane** on [command] and returns its pane id.
///
/// Null means there was nowhere visible to run it, and the command is then not
/// run at all: a setup script whose output nobody can see is the failure this
/// feature exists to remove, so it is refused rather than done quietly. The
/// callback may throw; the reason is carried into the verdict.
typedef WorktreeSetupPaneOpener =
    String? Function(WorktreeSetupCommand command);

/// Files a finished report. See `WorktreeSetupDao.record`.
typedef WorktreeSetupRecorder = void Function(WorktreeSetupReport report);

/// Does to a new worktree what its repository asked for: copies the gitignored
/// paths git will not put there, then opens a pane on the setup command.
///
/// **Everything runs in the repository's own environment**, through the
/// `CommandRunner` the factory hands out for it — see `worktreeCopierFor` and
/// `GitService`. That was the question the backlog said this feature lives or
/// dies on, and the answer is that the existing runner already covers all four
/// environment kinds for both halves.
///
/// **The worktree is created whether or not any of this works.** Nothing here
/// throws: every failure becomes a sentence on a recorded report. Rolling a
/// checkout back because a setup script exited non-zero would destroy the
/// expensive thing to punish the cheap one, and it would do it at the moment a
/// session was being launched into it.
class WorktreeSetupService {
  WorktreeSetupService({
    required this.runnerFactory,
    required this.lookup,
    required this.record,
    this.openPane,
    Clock? clock,
  }) : clock = clock ?? const SystemClock();

  final CommandRunnerFactory runnerFactory;
  final WorktreeSetupLookup lookup;
  final WorktreeSetupRecorder record;

  /// Null in a container with no terminal — a test, or the companion's
  /// headless surface. A configured command is then refused in words rather
  /// than run where nobody can see it.
  final WorktreeSetupPaneOpener? openPane;

  final Clock clock;

  /// The reports whose command is still expected to be running, by pane id.
  ///
  /// **In memory, and complete for every case that can happen.** The only
  /// consumer is [noteExit], and the only exits it can be handed are of panes
  /// this process opened: closing the app kills every pane, and a *restored*
  /// setup pane never re-runs its command — `shouldRestartOnActivate` excludes
  /// agent panes for exactly that reason. So a column on
  /// `worktree_setup_runs` would be a durable index for a lookup that cannot
  /// outlive the process. An entry is dropped the moment its exit is recorded;
  /// what is left over is one small record per worktree whose setup pane the
  /// user closed by hand, which the terminal deliberately does not announce.
  final Map<String, WorktreeSetupReport> _pending = {};

  /// Sets [worktree] up for [repo]. Returns the report, or **null when there
  /// was nothing to do** — no recorded checkout, or a checkout with no setting.
  ///
  /// A checkout nobody configured costs nothing at all here: no process, no
  /// stat, and no row. That matters because this is on the path of every
  /// worktree the app makes, including a fan-out of four at once.
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
    record(report);
    final pane = report.command?.paneId;
    if (pane != null && (report.command?.result.isPending ?? false)) {
      _pending[pane] = report;
    }
    return report;
  }

  /// The pane a setup command was running in has stopped. Returns the corrected
  /// report, or **null when no setup was waiting on that pane** — which is
  /// nearly every pane exit in the app, so this has to be cheap and silent.
  WorktreeSetupReport? noteExit(String paneId, int? exitCode) {
    final pending = _pending.remove(paneId);
    if (pending == null) return null;
    final corrected = pending.withCommand(
      pending.command?.afterExit(exitCode),
    );
    record(corrected);
    return corrected;
  }

  /// The copy half: one `git check-ignore` for the whole list, then one copy
  /// per surviving path.
  ///
  /// Ordered before the command on purpose. The command is usually the thing
  /// that *uses* what was copied — `flutter pub get` against a copied
  /// `.dart_tool` is the whole point — so a pane opened first would race it.
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
      // Null is git refusing the question, and it is never read as "tracked"
      // *or* as "ignored": copying on a reading we could not take is how a
      // branch's own files get overwritten silently.
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
          // Joined with the environment's own separator, never the host's:
          // `.karmashala-worktrees/app-s1/.dart_tool` for a distribution and
          // a backslash path for Windows. The setting is always `/`-separated.
          source: context.joinAll([repo.path, ...path.split('/')]),
          destination: context.joinAll([worktree.path, ...path.split('/')]),
        ),
      );
    }
    return verdicts;
  }

  /// The command half: a pane, or a refusal saying why there is not one.
  ///
  /// **It is started and not awaited.** A setup script has no bound — the one
  /// this exists for downloads a package cache — and the caller is inside
  /// `createForSession`, which a session launch is waiting on. Holding that on
  /// an arbitrary script would let a hung `pub get` hang the window. What the
  /// user gets instead is the pane itself, from the moment it opens; the exit
  /// code arrives later through `PaneExitSignal`, or is honestly never
  /// recorded.
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
