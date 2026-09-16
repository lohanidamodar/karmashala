import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/git/application/git_providers.dart';
import 'package:karmashala/src/features/git/application/worktree_setup_providers.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/terminal/application/pane_exit_signal.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// The app's own wiring, end to end: a worktree created through
/// `worktreeServiceProvider` reads the setting out of the database, opens a
/// real pane through the terminal controller, and records a verdict.
void main() {
  late AppDatabase db;
  late FakeCommandRunner runner;
  late ProviderContainer container;

  const wslRepo = EnvironmentPath(
    environmentId: 'wsl:Ubuntu',
    path: '/home/me/app',
  );

  void build() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db)
      ..upsert(windowsEnv())
      ..upsert(wslEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(
      repository(environmentId: 'wsl:Ubuntu', path: '/home/me/app'),
    );
    runner = FakeCommandRunner(
      environmentId: 'wsl:Ubuntu',
      responder: (request) => request.arguments.contains('check-ignore')
          ? const CommandResult(exitCode: 0, stdout: '.dart_tool', stderr: '')
          : const CommandResult(exitCode: 0, stdout: '', stderr: ''),
    );
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: runner),
        ),
      ],
    );
    // Watched, not read — the observer's subscriptions are paused otherwise,
    // which is the failure its own doc warns about.
    container.listen(worktreeSetupExitObserverProvider, (_, _) {});
  }

  setUp(build);
  tearDown(() {
    container.dispose();
    db.close();
  });

  Future<EnvironmentPath> create() async {
    final worktree = await container
        .read(worktreeServiceProvider)
        .createForSession(
          repo: wslRepo,
          worktreeName: 's1',
          branch: 'session/s1',
        );
    return worktree.path;
  }

  test('a checkout with no setting opens no pane and records nothing', () async {
    await create();
    expect(container.read(terminalSessionsControllerProvider).tabs, isEmpty);
    expect(
      container.read(worktreeSetupDaoProvider).runsFor('r1'),
      isEmpty,
      reason: 'nothing happened, so there is nothing to say about it',
    );
  });

  test('the command reaches a real pane, pointed at the distribution', () async {
    container.read(worktreeSetupDaoProvider).save(
      'r1',
      const WorktreeSetup(
        command: ['flutter', 'pub', 'get'],
        copyPaths: ['.dart_tool'],
      ),
      testTime,
    );

    final path = await create();
    final terminals = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    final tab = container
        .read(terminalSessionsControllerProvider)
        .tabs
        .single;
    final instance =
        terminals.instanceFor(tab.focusedPaneId) as FakeTerminalInstance;
    final launch = instance.agentLaunch!;

    expect(launch.executable, 'flutter');
    expect(launch.arguments, ['pub', 'get']);
    expect(launch.workingDirectory, path.path);
    // The whole point: the pane is pointed at the *repository's* environment,
    // so `wrapForPty` builds `cmd.exe /c wsl.exe -d Ubuntu …` rather than
    // running a Windows `flutter` against a Linux checkout — CLAUDE.md §17.
    expect(launch.wslDistribution, 'Ubuntu');
    expect(launch.sshHostId, isNull);
    expect(launch.agentId, kWorktreeSetupAgentId);
    // Not a session's pane: nothing here is an agent conversation.
    expect(launch.sessionId, isNull);
    expect(launch.title, contains('app-s1'));

    final run = container.read(worktreeSetupDaoProvider).lastRun('r1', path)!;
    expect(run.command!.result, WorktreeCommandResult.running);
    expect(run.command!.paneId, tab.focusedPaneId);
    expect(run.command!.exitCode, isNull);
    expect(run.copies.single.path, '.dart_tool');
  });

  test('an SSH checkout is pointed at its host, not at this one', () async {
    ExecutionEnvironmentDao(db).upsert(sshEnvFixture());
    RepositoryDao(db).insert(
      repository(
        id: 'r2',
        environmentId: 'ssh:h1',
        path: '/srv/app',
        name: 'remote',
      ),
    );
    container.read(worktreeSetupDaoProvider).save(
      'r2',
      const WorktreeSetup(command: ['make', 'setup']),
      testTime,
    );

    await container.read(worktreeServiceProvider).createForSession(
      repo: const EnvironmentPath(
        environmentId: 'ssh:h1',
        path: '/srv/app',
      ),
      worktreeName: 's1',
      branch: 'session/s1',
    );

    final terminals = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    final tab = container
        .read(terminalSessionsControllerProvider)
        .tabs
        .single;
    final launch =
        (terminals.instanceFor(tab.focusedPaneId) as FakeTerminalInstance)
            .agentLaunch!;
    expect(launch.sshHostId, 'h1');
    expect(launch.wslDistribution, isNull);
  });

  test('the pane stopping turns "running" into a recorded verdict', () async {
    container.read(worktreeSetupDaoProvider).save(
      'r1',
      const WorktreeSetup(command: ['flutter', 'pub', 'get']),
      testTime,
    );
    final path = await create();
    final paneId = container
        .read(terminalSessionsControllerProvider)
        .tabs
        .single
        .focusedPaneId;
    final before = container.read(worktreeSetupRevisionProvider);

    container.read(paneExitProvider.notifier).record(
      PaneExit(paneId: paneId, sessionId: null, exitCode: 1),
    );

    final run = container.read(worktreeSetupDaoProvider).lastRun('r1', path)!;
    expect(run.command!.result, WorktreeCommandResult.failed);
    expect(run.command!.exitCode, 1);
    expect(run.verdict, WorktreeSetupVerdict.attention);
    expect(
      container.read(worktreeSetupRevisionProvider),
      greaterThan(before),
      reason: 'the surface is told, rather than asking again on a timer',
    );
  });

  test('some other pane stopping changes nothing', () async {
    container.read(worktreeSetupDaoProvider).save(
      'r1',
      const WorktreeSetup(command: ['make']),
      testTime,
    );
    final path = await create();
    container.read(paneExitProvider.notifier).record(
      const PaneExit(paneId: 'a-shell', sessionId: null, exitCode: 3),
    );
    expect(
      container.read(worktreeSetupDaoProvider).lastRun('r1', path)!.command!
          .result,
      WorktreeCommandResult.running,
    );
  });

  test('the setup pane is not a session pane, and is stored as one restore '
      'will not re-run', () async {
    container.read(worktreeSetupDaoProvider).save(
      'r1',
      const WorktreeSetup(command: ['make']),
      testTime,
    );
    await create();
    final paneId = container
        .read(terminalSessionsControllerProvider)
        .tabs
        .single
        .focusedPaneId;
    final instance =
        container.read(terminalSessionsControllerProvider.notifier)
                .instanceFor(paneId)
            as FakeTerminalInstance;
    // `shouldRestartOnActivate` excludes agent panes, so a restored setup pane
    // replays its scrollback and runs nothing.
    expect(AgentPaneLaunch.isAgentProfileId(instance.profileId), isTrue);
  });
}
