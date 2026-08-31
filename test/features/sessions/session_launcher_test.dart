import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/util/clock_provider.dart';
import 'package:chitragupta/src/core/util/id_generator_provider.dart';
import 'package:chitragupta/src/features/agents/data/agent_installation_dao.dart';
import 'package:chitragupta/src/features/agents/domain/agent_descriptor.dart';
import 'package:chitragupta/src/features/agents/domain/agent_ids.dart';
import 'package:chitragupta/src/features/agents/domain/agent_registry.dart';
import 'package:chitragupta/src/features/agents/application/agent_providers.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/environments/domain/environment_path.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
import 'package:chitragupta/src/features/repositories/data/repository_dao.dart';
import 'package:chitragupta/src/features/sessions/application/session_launcher.dart';
import 'package:chitragupta/src/features/sessions/application/session_working_directory.dart';
import 'package:chitragupta/src/features/sessions/data/session_dao.dart';
import 'package:chitragupta/src/features/sessions/domain/session_launch.dart';
import 'package:chitragupta/src/features/settings/application/settings_controller.dart';
import 'package:chitragupta/src/features/settings/domain/permission_mode.dart';
import 'package:chitragupta/src/features/settings/domain/settings.dart';
import 'package:chitragupta/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// An agent that exists only as a registry entry: no `AgentKind`, no protocol
/// adapter, no store. If this can run, "adding an agent is a data entry" is
/// true of the runtime and not only of discovery.
const _rover = AgentDescriptor(
  id: 'roverCli',
  displayName: 'Rover CLI',
  binaries: AgentBinaries(windows: ['rover'], posix: ['rover']),
  launch: AgentLaunchSpec(
    baseArguments: ['--headless'],
    permissionModes: {
      PermissionMode.ask: PermissionModeMapping.exact(['--careful']),
      PermissionMode.bypass: PermissionModeMapping.exact(['--trust-me']),
    },
    interactiveResume: AgentResume.flag('--continue'),
  ),
);

/// The same agent, but one whose CLI takes an opening message.
const _talkative = AgentDescriptor(
  id: 'roverCli',
  displayName: 'Rover CLI',
  binaries: AgentBinaries(windows: ['rover'], posix: ['rover']),
  launch: AgentLaunchSpec(
    baseArguments: ['--headless'],
    acceptsPromptArgument: true,
    permissionModes: {
      PermissionMode.ask: PermissionModeMapping.exact(['--careful']),
    },
  ),
);

({ProviderContainer container, AppDatabase db}) harness({
  Settings settings = const Settings(),
  AgentRegistry registry = const AgentRegistry([_rover]),
  Set<String> missingDirectories = const {},
}) {
  final db = AppDatabase.memory();
  ExecutionEnvironmentDao(db)
    ..upsert(windowsEnv())
    ..upsert(wslEnv());
  ProjectDao(db).insert(project());
  RepositoryDao(db).insert(repository());
  AgentInstallationDao(db).insert(agentInstallation(agentId: 'roverCli'));

  // The same process-free terminal the controller's own tests use, so the pane
  // behaviour exercised here is not a second, friendlier fake.
  final container = ProviderContainer(
    overrides: [
      ...fakeTerminalOverrides(database: db),
      clockProvider.overrideWithValue(FixedClock(testTime)),
      idGeneratorProvider.overrideWithValue(SequentialIdGenerator('s-')),
      agentRegistryProvider.overrideWithValue(registry),
      settingsControllerProvider.overrideWith(() => _StaticSettings(settings)),
      // The filesystem seam. Nothing under `C:\src\demo` exists on a test
      // machine, so the default would call every recorded directory gone.
      sessionDirectoryPresentProvider.overrideWithValue(
        (directory) => !missingDirectories.contains(directory.path),
      ),
    ],
  );
  return (container: container, db: db);
}

class _StaticSettings extends SettingsController {
  _StaticSettings(this._settings);
  final Settings _settings;

  @override
  Settings build() => _settings;
}

void main() {
  test('a registry-only agent runs in a PTY pane, with a session row', () {
    final h = harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);

    final launched = h.container
        .read(sessionLauncherProvider)
        .launch(
          SessionLaunchRequest(
            repository: repository(),
            installation: agentInstallation(agentId: 'roverCli'),
            title: 'Rover run',
            purpose: SessionPurpose.newSession,
          ),
        );

    return launched.then((result) {
      // The row exists, knows its pane, and says it is a pane session.
      final stored = SessionDao(h.db).getById(result.session.id)!;
      expect(stored.surface, SessionSurface.pane);
      expect(stored.paneId, isNotNull);
      expect(stored.paneId, result.paneId);
      // No readable store, so no chat view — a capability answer, not a failure.
      expect(stored.view, SessionView.terminal);

      // And a real pane is running it, launched from the descriptor's own
      // vocabulary rather than from anything hardcoded.
      final controller = h.container.read(
        terminalSessionsControllerProvider.notifier,
      );
      final instance = controller.instanceFor(result.paneId!)!;
      final launch = instance.agentLaunch!;
      expect(launch.agentId, 'roverCli');
      expect(launch.arguments, ['--careful']);
      expect(launch.sessionId, stored.id);
      expect(launch.workingDirectory, repository().path.path);
      // Protocol arguments never reach an interactive launch.
      expect(launch.arguments, isNot(contains('--headless')));
    });
  });

  test('permission mode comes from the purpose, in one place', () async {
    const settings = Settings();
    final h = harness(
      settings: settings.withPermissions(
        'roverCli',
        const AgentPermissions(
          newSessions: PermissionMode.ask,
          existingSessions: PermissionMode.bypass,
        ),
      ),
    );
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    final launcher = h.container.read(sessionLauncherProvider);

    expect(
      launcher.permissionFor('roverCli', SessionPurpose.newSession),
      PermissionMode.ask,
    );
    expect(
      launcher.permissionFor('roverCli', SessionPurpose.existingSession),
      PermissionMode.bypass,
    );

    // The sharpest divergence the audit found: a resume used to be started
    // under the *new*-session preference and vice versa. Now the flags on the
    // command line follow the purpose.
    final resumed = await launcher.launch(
      SessionLaunchRequest(
        repository: repository(),
        installation: agentInstallation(agentId: 'roverCli'),
        title: 'Continue',
        purpose: SessionPurpose.existingSession,
        resumeExternalSessionId: 'external-1',
      ),
    );
    final instance = h.container
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(resumed.paneId!)!;
    expect(instance.agentLaunch!.arguments, [
      '--trust-me',
      '--continue',
      'external-1',
    ]);
  });

  test('a launched session is stamped with the mode it ran under', () async {
    final h = harness(
      settings: const Settings().withPermissions(
        'roverCli',
        const AgentPermissions(
          newSessions: PermissionMode.ask,
          existingSessions: PermissionMode.bypass,
        ),
      ),
    );
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    final launcher = h.container.read(sessionLauncherProvider);

    final launched = await launcher.launch(
      SessionLaunchRequest(
        repository: repository(),
        installation: agentInstallation(agentId: 'roverCli'),
        title: 'Stamped',
        purpose: SessionPurpose.newSession,
      ),
    );

    // The mode used to die with the local that held it, so nothing could say
    // what a running session was running under.
    final stored = SessionDao(h.db).getById(launched.session.id)!;
    expect(stored.permissionMode, PermissionMode.ask);
  });

  test('a session keeps its own mode when the global default moves', () async {
    final h = harness(
      settings: const Settings().withPermissions(
        'roverCli',
        const AgentPermissions(existingSessions: PermissionMode.bypass),
      ),
    );
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    final launcher = h.container.read(sessionLauncherProvider);

    final launched = await launcher.launch(
      SessionLaunchRequest(
        repository: repository(),
        installation: agentInstallation(agentId: 'roverCli'),
        title: 'Mine',
        purpose: SessionPurpose.newSession,
      ),
    );
    final id = launched.session.id;

    // Stamped `ask` at creation. The agent's *existing-session* default is
    // `bypass`, so a resolver that re-read the setting would silently escalate
    // this session to full autonomy on its next resume. It must not.
    expect(
      launcher.permissionFor(
        'roverCli',
        SessionPurpose.existingSession,
        sessionMode: SessionDao(h.db).getById(id)!.permissionMode,
      ),
      PermissionMode.ask,
    );

    // The override is what changes it, and it is readable back as the
    // session's own rather than as an inherited default.
    launcher.setPermissionMode(id, PermissionMode.bypass);
    final effective = launcher.effectivePermissionFor(id)!;
    expect(effective.mode, PermissionMode.bypass);
    expect(effective.inherited, isFalse);
    expect(effective.descriptor?.id, 'roverCli');
  });

  test('a row from before v11 falls back to the agent default', () async {
    final h = harness(
      settings: const Settings().withPermissions(
        'roverCli',
        const AgentPermissions(existingSessions: PermissionMode.acceptEdits),
      ),
    );
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    final launcher = h.container.read(sessionLauncherProvider);

    final launched = await launcher.launch(
      SessionLaunchRequest(
        repository: repository(),
        installation: agentInstallation(agentId: 'roverCli'),
        title: 'Legacy',
        purpose: SessionPurpose.newSession,
      ),
    );
    // Exactly what an old row looks like: the column exists and is null.
    h.db.execute('UPDATE sessions SET permission_mode = NULL WHERE id = ?;', [
      launched.session.id,
    ]);

    expect(
      SessionDao(h.db).getById(launched.session.id)!.permissionMode,
      isNull,
    );
    final effective = launcher.effectivePermissionFor(launched.session.id)!;
    expect(effective.mode, PermissionMode.acceptEdits);
    // Null is "never recorded", not a defaulted `ask` — the control says
    // "inherited" rather than claiming the session chose this.
    expect(effective.inherited, isTrue);
  });

  test('a spawned session records its parent and is capped', () async {
    final h = harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    final launcher = h.container.read(sessionLauncherProvider);

    SessionLaunchRequest request(String? parent) => SessionLaunchRequest(
      repository: repository(),
      installation: agentInstallation(agentId: 'roverCli'),
      title: 'Spawned',
      purpose: SessionPurpose.newSession,
      parentSessionId: parent,
    );

    final root = await launcher.launch(request(null));
    final child = await launcher.launch(request(root.session.id));
    final grandchild = await launcher.launch(request(child.session.id));

    expect(root.session.parentSessionId, isNull);
    expect(child.session.parentSessionId, root.session.id);
    // Read back from storage: the chain is the only record of depth.
    expect(
      SessionDao(h.db).getById(grandchild.session.id)!.parentSessionId,
      child.session.id,
    );
    expect(
      SessionDao(h.db).childrenOf(root.session.id).single.id,
      child.session.id,
    );

    await expectLater(
      launcher.launch(request(grandchild.session.id)),
      throwsA(isA<SessionDepthRefused>()),
    );
    // And nothing was created for the refused call.
    expect(SessionDao(h.db).getAll().length, 3);
  });

  test('a spawned session names its parent in its opening prompt', () async {
    final h = harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    final launcher = h.container.read(sessionLauncherProvider);

    // The rover agent does not accept a prompt argument, so use a built-in that
    // does — the attribution is what is under test, not the delivery.
    final claudeHarness = harness(registry: AgentRegistry.builtIn);
    addTearDown(claudeHarness.db.close);
    addTearDown(claudeHarness.container.dispose);
    AgentInstallationDao(
      claudeHarness.db,
    ).insert(agentInstallation(id: 'i2', agentId: AgentIds.claudeCode));
    final claudeLauncher = claudeHarness.container.read(
      sessionLauncherProvider,
    );

    final parent = await claudeLauncher.launch(
      SessionLaunchRequest(
        repository: repository(),
        installation: agentInstallation(id: 'i2', agentId: AgentIds.claudeCode),
        title: 'Fix [urgent] crash',
        purpose: SessionPurpose.newSession,
      ),
    );
    final child = await claudeLauncher.launch(
      SessionLaunchRequest(
        repository: repository(),
        installation: agentInstallation(id: 'i2', agentId: AgentIds.claudeCode),
        title: 'Helper',
        purpose: SessionPurpose.newSession,
        parentSessionId: parent.session.id,
        firstMessage: 'run the tests',
      ),
    );

    final instance = claudeHarness.container
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(child.paneId!)!;
    final prompt = instance.agentLaunch!.arguments.last;
    expect(prompt, contains('Fix [urgent] crash'));
    expect(prompt, endsWith('run the tests'));
    expect(launcher, isNotNull);
  });

  test('Claude Code is launched with our own id as its session id', () async {
    final h = harness(registry: AgentRegistry.builtIn);
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    AgentInstallationDao(
      h.db,
    ).insert(agentInstallation(id: 'i2', agentId: AgentIds.claudeCode));

    final launched = await h.container
        .read(sessionLauncherProvider)
        .launch(
          SessionLaunchRequest(
            repository: repository(),
            installation: agentInstallation(
              id: 'i2',
              agentId: AgentIds.claudeCode,
            ),
            title: 'Claude',
            purpose: SessionPurpose.newSession,
          ),
        );
    // One string is both ids, so the transcript backing the chat view is
    // locatable at launch rather than guessed at afterwards.
    expect(launched.session.externalSessionId, launched.session.id);
    // And the agent has a chat view, because its store is readable.
    expect(launched.session.view, SessionView.chat);
  });

  test('a WSL session is wrapped for wsl.exe', () async {
    final h = harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    RepositoryDao(h.db).insert(
      repository(id: 'r2', environmentId: 'wsl:Ubuntu', path: '/home/u/app'),
    );

    final launched = await h.container
        .read(sessionLauncherProvider)
        .launch(
          SessionLaunchRequest(
            repository: repository(
              id: 'r2',
              environmentId: 'wsl:Ubuntu',
              path: '/home/u/app',
            ),
            installation: agentInstallation(agentId: 'roverCli'),
            title: 'In WSL',
            purpose: SessionPurpose.newSession,
          ),
        );
    final instance = h.container
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(launched.paneId!)!;
    expect(instance.agentLaunch!.wslDistribution, 'Ubuntu');
  });

  test('answering a prompt presses the key and nothing else', () async {
    final h = harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    final launcher = h.container.read(sessionLauncherProvider);

    final launched = await launcher.launch(
      SessionLaunchRequest(
        repository: repository(),
        installation: agentInstallation(agentId: 'roverCli'),
        title: 'Blocked',
        purpose: SessionPurpose.newSession,
      ),
    );
    final instance = h.container
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(launched.paneId!)!;
    final written = <String>[];
    instance.terminal.onOutput = written.add;

    expect(launcher.answerPrompt(launched.session.id, '\r'), isTrue);
    // Exactly the key, once. `sendTo` trims and appends a carriage return to
    // submit a *message*; doing either here would erase the whole payload or
    // press a second key nobody asked for.
    expect(written, ['\r']);

    written.clear();
    expect(launcher.answerPrompt(launched.session.id, '\x1b'), isTrue);
    expect(written, ['\x1b']);

    // Nothing to press is a refusal the caller can report, not a silent no-op.
    written.clear();
    expect(launcher.answerPrompt(launched.session.id, ''), isFalse);
    expect(launcher.answerPrompt('no-such-session', '\r'), isFalse);
    expect(written, isEmpty);
  });

  test('a first message an agent cannot take refuses the launch', () async {
    // `agentPaneArguments` drops the prompt when the CLI takes none, and every
    // caller above reported success anyway: fan-out recorded the candidate as
    // started, and the MCP spawn tool answered "opened a new session" — so a
    // model believed its instruction had landed at an agent that came up bare.
    final h = harness();
    addTearDown(h.container.dispose);
    addTearDown(h.db.close);

    await expectLater(
      h.container.read(sessionLauncherProvider).launch(
        SessionLaunchRequest(
          repository: repository(),
          installation: agentInstallation(agentId: 'roverCli'),
          title: 'Rover run',
          purpose: SessionPurpose.newSession,
          firstMessage: 'compare these two approaches',
        ),
      ),
      throwsA(isA<SessionLaunchRefused>()),
    );
    expect(
      SessionDao(h.db).getAll(),
      isEmpty,
      reason: 'refused before anything was written',
    );
  });

  test('an agent that does take one is launched with it', () async {
    final h = harness(registry: const AgentRegistry([_talkative]));
    addTearDown(h.container.dispose);
    addTearDown(h.db.close);

    final result = await h.container.read(sessionLauncherProvider).launch(
      SessionLaunchRequest(
        repository: repository(),
        installation: agentInstallation(agentId: 'roverCli'),
        title: 'Rover run',
        purpose: SessionPurpose.newSession,
        firstMessage: 'compare these two approaches',
      ),
    );

    expect(SessionDao(h.db).getById(result.session.id), isNotNull);
  });

  group('the directory a session runs in', () {
    const subdirectory = r'C:\src\demo\app\packages\ui';
    const elsewhere = EnvironmentPath(
      environmentId: 'windows',
      path: subdirectory,
    );

    /// A session adopted out of a terminal pane: a real row, in a
    /// subdirectory, with the CLI's own id and no pane of its own.
    void adoptedIn(AppDatabase db, EnvironmentPath directory) {
      SessionDao(db).insert(
        session(
          id: 'adopted-1',
          title: 'Adopted',
          workingDirectory: directory,
        ).copyWith(externalSessionId: 'cli-abc'),
      );
    }

    test('a launched session records where it was started', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      final launched = await h.container
          .read(sessionLauncherProvider)
          .launch(
            SessionLaunchRequest(
              repository: repository(),
              installation: agentInstallation(agentId: 'roverCli'),
              title: 'Rover run',
              purpose: SessionPurpose.newSession,
            ),
          );

      // The same fact as an adopted session's, from the one place that already
      // knew it. Two sources for it would drift.
      final stored = SessionDao(h.db).getById(launched.session.id)!;
      expect(stored.workingDirectory, repository().path);
      expect(stored.worktree, isNull);
      expect(stored.useWorktree, isFalse);
    });

    test('a session joining a worktree records the worktree', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      const worktree = EnvironmentPath(
        environmentId: 'windows',
        path: r'C:\src\demo\.chitragupta-worktrees\app-s-1',
      );

      final launched = await h.container
          .read(sessionLauncherProvider)
          .launch(
            SessionLaunchRequest(
              repository: repository(),
              installation: agentInstallation(agentId: 'roverCli'),
              title: 'In a worktree',
              purpose: SessionPurpose.newSession,
              existingWorktree: worktree,
            ),
          );

      final stored = SessionDao(h.db).getById(launched.session.id)!;
      expect(stored.workingDirectory, worktree);
      // And the worktree still says it is one, which the cwd never does.
      expect(stored.worktree, worktree);
      expect(stored.useWorktree, isTrue);
    });

    test('an adopted session in a subdirectory resumes in it', () async {
      // The failure this closes: Claude Code and Codex key their conversation
      // stores by working directory, so a resume from the repository root can
      // silently start a *new* conversation wearing this row's title.
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      adoptedIn(h.db, elsewhere);

      final resumed = await h.container
          .read(sessionLauncherProvider)
          .launch(
            SessionLaunchRequest(
              repository: repository(),
              installation: agentInstallation(agentId: 'roverCli'),
              title: 'Adopted',
              purpose: SessionPurpose.existingSession,
              resumeExternalSessionId: 'cli-abc',
              // Exactly what the Explorer passes: the row has no worktree, so
              // nothing but the recorded directory can answer.
            ),
          );

      expect(resumed.session.id, 'adopted-1');
      final instance = h.container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(resumed.paneId!)!;
      expect(instance.agentLaunch!.workingDirectory, subdirectory);
      expect(resumed.workingDirectoryNotice, isNull);
    });

    test('a resume with nothing recorded still starts at the root', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      SessionDao(h.db).insert(
        session(id: 'old-1', title: 'Before v22')
            .copyWith(externalSessionId: 'cli-old'),
      );

      final resumed = await h.container
          .read(sessionLauncherProvider)
          .launch(
            SessionLaunchRequest(
              repository: repository(),
              installation: agentInstallation(agentId: 'roverCli'),
              title: 'Before v22',
              purpose: SessionPurpose.existingSession,
              resumeExternalSessionId: 'cli-old',
            ),
          );

      final instance = h.container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(resumed.paneId!)!;
      expect(instance.agentLaunch!.workingDirectory, repository().path.path);
      expect(resumed.workingDirectoryNotice, isNull);
    });

    test('a resumed worktree row goes back to its worktree', () async {
      // The MCP `open_session` tool resumes without naming a worktree at all,
      // so before the row could answer, every resume from an agent put the
      // session back in the repository root. A row written before v22 records
      // no directory but does record its worktree, which is the same fact.
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      const worktree = EnvironmentPath(
        environmentId: 'windows',
        path: r'C:\src\demo\.chitragupta-worktrees\app-old',
      );
      SessionDao(h.db).insert(
        session(id: 'wt-1', title: 'In a worktree', useWorktree: true,
                worktree: worktree)
            .copyWith(externalSessionId: 'cli-wt'),
      );

      final resumed = await h.container
          .read(sessionLauncherProvider)
          .launch(
            SessionLaunchRequest(
              repository: repository(),
              installation: agentInstallation(agentId: 'roverCli'),
              title: 'In a worktree',
              purpose: SessionPurpose.existingSession,
              resumeExternalSessionId: 'cli-wt',
            ),
          );

      final instance = h.container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(resumed.paneId!)!;
      expect(instance.agentLaunch!.workingDirectory, worktree.path);
    });

    test('a stated directory beats the row and the repository', () async {
      // What a handoff and a fork need: continue the work *where it is*.
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      final launched = await h.container
          .read(sessionLauncherProvider)
          .launch(
            SessionLaunchRequest(
              repository: repository(),
              installation: agentInstallation(agentId: 'roverCli'),
              title: 'Handed over',
              purpose: SessionPurpose.newSession,
              workingDirectory: elsewhere,
            ),
          );

      final instance = h.container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(launched.paneId!)!;
      expect(instance.agentLaunch!.workingDirectory, subdirectory);
      expect(SessionDao(h.db).getById(launched.session.id)!.workingDirectory,
          elsewhere);
    });

    test('a directory that has gone away falls back and says so', () async {
      final h = harness(missingDirectories: const {subdirectory});
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      adoptedIn(h.db, elsewhere);

      final resumed = await h.container
          .read(sessionLauncherProvider)
          .launch(
            SessionLaunchRequest(
              repository: repository(),
              installation: agentInstallation(agentId: 'roverCli'),
              title: 'Adopted',
              purpose: SessionPurpose.existingSession,
              resumeExternalSessionId: 'cli-abc',
            ),
          );

      // It resumes rather than throwing, in the only directory left.
      final instance = h.container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(resumed.paneId!)!;
      expect(instance.agentLaunch!.workingDirectory, repository().path.path);
      // And it says so, naming both directories, rather than resuming
      // somewhere else in silence.
      expect(resumed.workingDirectoryNotice, contains(subdirectory));
      expect(
        resumed.workingDirectoryNotice,
        contains(repository().path.path),
      );

      // The record is kept. A missing folder is often temporary — an unmounted
      // drive, a WSL distro that is not running — and overwriting it would turn
      // that into permanent data loss.
      expect(
        SessionDao(h.db).getById('adopted-1')!.workingDirectory,
        elsewhere,
      );
    });
  });
}
