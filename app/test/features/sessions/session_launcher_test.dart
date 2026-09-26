import 'package:karmashala_store/database.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/application/session_working_directory.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/grid.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

import '../../support/fakes.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/workspace_mirror.dart';
import '../../support/permission_fixtures.dart';
import '../terminal/fake_instance.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';

/// An agent that exists only as a registry entry: no adapter code, no protocol
/// adapter, no store. If this can run, "adding an agent is a data entry" is
/// true of the runtime and not only of discovery.
const _rover = AgentDescriptor(
  id: 'roverCli',
  displayName: 'Rover CLI',
  binaries: AgentBinaries(windows: ['rover'], posix: ['rover']),
  launch: AgentLaunchSpec(
    baseArguments: ['--headless'],
    permission: testPermissionSupport,
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
    prompt: AgentPromptSupport.positional(),
    permission: testPermissionSupport,
  ),
);

Future<({ProviderContainer container, AppDatabase db, FakeDataServer server})>
harness({
  Settings settings = const Settings(),
  AgentRegistry registry = const AgentRegistry([DataOnlyAgentAdapter(_rover)]),
  Set<String> missingDirectories = const {},
}) async {
  final db = AppDatabase.memory();
  final server = FakeDataServer()..mirrorInto(db);
  server.environmentRows
    ..upsert(windowsEnv())
    ..upsert(wslEnv());
  server.projectRows.insert(project());
  server.repositoryRows.insert(repository());
  server.installationRows.insert(agentInstallation(agentId: 'roverCli'));

  // The same process-free terminal the controller's own tests use, so the pane
  // behaviour exercised here is not a second, friendlier fake.
  final container = ProviderContainer(
    overrides: [
      ...fakeTerminalOverrides(database: db),
      await server.override(),
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
  return (container: container, db: db, server: server);
}

class _StaticSettings extends SettingsController {
  _StaticSettings(this._settings);
  final Settings _settings;

  @override
  Settings build() => _settings;
}

void main() {
  test('a registry-only agent runs in a PTY pane, with a session row', () async {
    final h = await harness();
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
      final stored = h.container
          .read(sessionsDataProvider)
          .getById(result.session.id)!;
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
      expect(launch.arguments, ['--mode', 'ask']);
      expect(launch.sessionId, stored.id);
      expect(launch.workingDirectory, repository().path.path);
      // Protocol arguments never reach an interactive launch.
      expect(launch.arguments, isNot(contains('--headless')));
    });
  });

  test('a title a person typed is recorded as theirs; a placeholder, a blank '
      'or a program\'s title leaves the naming to the agent', () async {
    final h = await harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    final launcher = h.container.read(sessionLauncherProvider);

    Future<Session> launch(String title, {required bool typed}) async {
      final launched = await launcher.launch(
        SessionLaunchRequest(
          repository: repository(),
          installation: agentInstallation(agentId: 'roverCli'),
          title: title,
          titleTyped: typed,
          purpose: SessionPurpose.newSession,
        ),
      );
      // The server's row, not only the launcher's copy of it.
      return h.server.sessionRows.getById(launched.session.id)!;
    }

    final typed = await launch(' phone 1c ', typed: true);
    expect(typed.title, 'phone 1c');
    expect(typed.titleByUser, isTrue);

    final placeholder = await launch('New session', typed: true);
    expect(placeholder.titleByUser, isFalse);

    final blank = await launch('  ', typed: true);
    expect(blank.title, 'Session');
    expect(blank.titleByUser, isFalse);

    final program = await launch('Rover run', typed: false);
    expect(program.titleByUser, isFalse);
  });

  test('permission mode comes from the purpose, in one place', () async {
    const settings = Settings();
    final h = await harness(
      settings: settings.withPermissions(
        'roverCli',
        const AgentPermissions(
          newSessions: askStored,
          existingSessions: bypassStored,
        ),
      ),
    );
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    final launcher = h.container.read(sessionLauncherProvider);

    expect(
      launcher.permissionFor('roverCli', SessionPurpose.newSession),
      askSelection,
    );
    expect(
      launcher.permissionFor('roverCli', SessionPurpose.existingSession),
      bypassSelection,
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
      '--bypass',
      '--continue',
      'external-1',
    ]);
  });

  test('a launch records a mode only when one was chosen', () async {
    final h = await harness(
      settings: const Settings().withPermissions(
        'roverCli',
        const AgentPermissions(
          newSessions: askStored,
          existingSessions: bypassStored,
        ),
      ),
    );
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    final launcher = h.container.read(sessionLauncherProvider);

    SessionLaunchRequest request({PermissionSelection? override}) =>
        SessionLaunchRequest(
          repository: repository(),
          installation: agentInstallation(agentId: 'roverCli'),
          title: 'Stamped',
          purpose: SessionPurpose.newSession,
          permissionOverride: override,
        );

    final defaulted = await launcher.launch(request());
    // It ran under `ask` — the new-session default — but nothing *chose* that,
    // so the row records no choice and the session goes on following the
    // setting. Stamping the resolved default here is what froze every session
    // at whatever Settings said the day it started.
    expect(
      h.container
          .read(sessionsDataProvider)
          .getById(defaulted.session.id)!
          .permissionMode,
      isNull,
    );
    expect(
      launcher.effectivePermissionFor(defaulted.session.id)!.inherited,
      isTrue,
    );

    final chosen = await launcher.launch(request(override: bypassSelection));
    // A caller that resolved a mode for this session *is* a choice, and it is
    // recorded so the next resume runs under it.
    expect(
      h.container
          .read(sessionsDataProvider)
          .getById(chosen.session.id)!
          .permissionMode,
      bypassStored,
    );
  });

  test('a session keeps its own mode when the global default moves', () async {
    final h = await harness(
      settings: const Settings().withPermissions(
        'roverCli',
        const AgentPermissions(existingSessions: bypassStored),
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

    // Chosen for this session. The agent's *existing-session* default is
    // `bypass`, so a resolver that re-read the setting would silently escalate
    // a deliberately careful session to full autonomy on its next resume. It
    // must not.
    launcher.setPermissionMode(id, askSelection);
    expect(
      launcher.permissionFor(
        'roverCli',
        SessionPurpose.existingSession,
        sessionMode: h.container
            .read(sessionsDataProvider)
            .getById(id)!
            .permissionMode,
      ),
      askSelection,
    );

    // And it reads back as the session's own rather than as an inherited
    // default, which is the difference the control has to be able to show.
    final effective = launcher.effectivePermissionFor(id)!;
    expect(effective.selection, askSelection);
    expect(effective.inherited, isFalse);
    expect(effective.descriptor?.id, 'roverCli');
  });

  test('a row from before v11 falls back to the agent default', () async {
    final h = await harness(
      settings: const Settings().withPermissions(
        'roverCli',
        const AgentPermissions(existingSessions: acceptEditsStored),
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
      h.container
          .read(sessionsDataProvider)
          .getById(launched.session.id)!
          .permissionMode,
      isNull,
    );
    final effective = launcher.effectivePermissionFor(launched.session.id)!;
    expect(effective.selection, acceptEditsSelection);
    // Null is "never recorded", not a defaulted `ask` — the control says
    // "inherited" rather than claiming the session chose this.
    expect(effective.inherited, isTrue);
  });

  test('a spawned session records its parent and is capped', () async {
    final h = await harness();
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
      h.container
          .read(sessionsDataProvider)
          .getById(grandchild.session.id)!
          .parentSessionId,
      child.session.id,
    );
    expect(
      h.container
          .read(sessionsDataProvider)
          .childrenOf(root.session.id)
          .single
          .id,
      child.session.id,
    );

    await expectLater(
      launcher.launch(request(grandchild.session.id)),
      throwsA(isA<SessionDepthRefused>()),
    );
    // And nothing was created for the refused call.
    expect(h.container.read(sessionsDataProvider).getAll().length, 3);
  });

  test('a spawned session names its parent in its opening prompt', () async {
    final h = await harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    final launcher = h.container.read(sessionLauncherProvider);

    // The rover agent does not accept a prompt argument, so use a built-in that
    // does — the attribution is what is under test, not the delivery.
    final claudeHarness = await harness(registry: AgentRegistry.builtIn);
    addTearDown(claudeHarness.db.close);
    addTearDown(claudeHarness.container.dispose);
    mirroredServer(claudeHarness.db).installationRows.insert(
      agentInstallation(id: 'i2', agentId: AgentIds.claudeCode),
    );
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
    final h = await harness(registry: AgentRegistry.builtIn);
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    mirroredServer(h.db).installationRows.insert(
      agentInstallation(id: 'i2', agentId: AgentIds.claudeCode),
    );

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
    final h = await harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    h.server.repositoryRows.insert(
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

  /// **The reported bug: the message arrived and was never submitted.**
  ///
  /// Codex's composer (`tui/src/bottom_pane/paste_burst.rs`) reads characters
  /// that arrive with no gap as a paste, and folds a Return inside that run
  /// into a newline. Measured 2026-09-08 against a real ConPTY: Codex 0.153.4
  /// left `body` + `\r` sitting in its composer on Windows *and* in WSL, and
  /// submitted it as soon as anything that is not a character came between the
  /// two. So a message now ends its typing before it presses Return.
  test('a sent message ends the typing before it presses Return', () async {
    final h = await harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    final launcher = h.container.read(sessionLauncherProvider);

    final launched = await launcher.launch(
      SessionLaunchRequest(
        repository: repository(),
        installation: agentInstallation(agentId: 'roverCli'),
        title: 'Listening',
        purpose: SessionPurpose.newSession,
      ),
    );
    final instance = h.container
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(launched.paneId!)!;
    final written = <String>[];
    instance.terminal.onOutput = written.add;

    expect(launcher.sendTo(launched.session.id, '  ship it  '), isTrue);
    expect(written, ['ship it', kEndOfLineKey, '\r']);

    // Still a refusal the caller can report rather than a silent drop.
    written.clear();
    expect(launcher.sendTo(launched.session.id, '   '), isFalse);
    expect(launcher.sendTo('no-such-session', 'ship it'), isFalse);
    expect(written, isEmpty);
  });

  test('answering a prompt presses the key and nothing else', () async {
    final h = await harness();
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

    expect(launcher.pressKeys(launched.session.id, '\r'), isTrue);
    // Exactly the key, once. `sendTo` trims and appends a carriage return to
    // submit a *message*; doing either here would erase the whole payload or
    // press a second key nobody asked for.
    expect(written, ['\r']);

    written.clear();
    expect(launcher.pressKeys(launched.session.id, '\x1b'), isTrue);
    expect(written, ['\x1b']);

    // Nothing to press is a refusal the caller can report, not a silent no-op.
    written.clear();
    expect(launcher.pressKeys(launched.session.id, ''), isFalse);
    expect(launcher.pressKeys('no-such-session', '\r'), isFalse);
    expect(written, isEmpty);
  });

  test('a first message an agent cannot take refuses the launch', () async {
    // `agentPaneArguments` drops the prompt when the CLI takes none, and every
    // caller above reported success anyway: fan-out recorded the candidate as
    // started, and the MCP spawn tool answered "opened a new session" — so a
    // model believed its instruction had landed at an agent that came up bare.
    final h = await harness();
    addTearDown(h.container.dispose);
    addTearDown(h.db.close);

    await expectLater(
      h.container
          .read(sessionLauncherProvider)
          .launch(
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
      h.container.read(sessionsDataProvider).getAll(),
      isEmpty,
      reason: 'refused before anything was written',
    );
  });

  test('an agent that does take one is launched with it', () async {
    final h = await harness(
      registry: const AgentRegistry([DataOnlyAgentAdapter(_talkative)]),
    );
    addTearDown(h.container.dispose);
    addTearDown(h.db.close);

    final result = await h.container
        .read(sessionLauncherProvider)
        .launch(
          SessionLaunchRequest(
            repository: repository(),
            installation: agentInstallation(agentId: 'roverCli'),
            title: 'Rover run',
            purpose: SessionPurpose.newSession,
            firstMessage: 'compare these two approaches',
          ),
        );

    expect(
      h.container.read(sessionsDataProvider).getById(result.session.id),
      isNotNull,
    );
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
      mirroredServer(db).sessionRows.insert(
        session(
          id: 'adopted-1',
          title: 'Adopted',
          workingDirectory: directory,
        ).copyWith(externalSessionId: 'cli-abc'),
      );
    }

    test('a launched session records where it was started', () async {
      final h = await harness();
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
      final stored = h.container
          .read(sessionsDataProvider)
          .getById(launched.session.id)!;
      expect(stored.workingDirectory, repository().path);
      expect(stored.worktree, isNull);
      expect(stored.useWorktree, isFalse);
    });

    test('a session joining a worktree records the worktree', () async {
      final h = await harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      const worktree = EnvironmentPath(
        environmentId: 'windows',
        path: r'C:\src\demo\.karmashala-worktrees\app-s-1',
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

      final stored = h.container
          .read(sessionsDataProvider)
          .getById(launched.session.id)!;
      expect(stored.workingDirectory, worktree);
      // And the worktree still says it is one, which the cwd never does.
      expect(stored.worktree, worktree);
      expect(stored.useWorktree, isTrue);
    });

    test('an adopted session in a subdirectory resumes in it', () async {
      // The failure this closes: Claude Code and Codex key their conversation
      // stores by working directory, so a resume from the repository root can
      // silently start a *new* conversation wearing this row's title.
      final h = await harness();
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
      final h = await harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      h.server.sessionRows.insert(
        session(
          id: 'old-1',
          title: 'Before v22',
        ).copyWith(externalSessionId: 'cli-old'),
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
      final h = await harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      const worktree = EnvironmentPath(
        environmentId: 'windows',
        path: r'C:\src\demo\.karmashala-worktrees\app-old',
      );
      h.server.sessionRows.insert(
        session(
          id: 'wt-1',
          title: 'In a worktree',
          useWorktree: true,
          worktree: worktree,
        ).copyWith(externalSessionId: 'cli-wt'),
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
      final h = await harness();
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
      expect(
        h.container
            .read(sessionsDataProvider)
            .getById(launched.session.id)!
            .workingDirectory,
        elsewhere,
      );
    });

    test('a directory that has gone away falls back and says so', () async {
      final h = await harness(missingDirectories: const {subdirectory});
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
      expect(resumed.workingDirectoryNotice, contains(repository().path.path));

      // The record is kept. A missing folder is often temporary — an unmounted
      // drive, a WSL distro that is not running — and overwriting it would turn
      // that into permanent data loss.
      expect(
        h.container
            .read(sessionsDataProvider)
            .getById('adopted-1')!
            .workingDirectory,
        elsewhere,
      );
    });
  });

  test('a launch says what it decided, in one line', () async {
    // This path had no logging, and four of its bugs were silent by
    // construction — a permission mode written over the row being reused, an
    // external session id never stored, a resume that quietly started a new
    // conversation, a dormant pane not reused so one session got two
    // terminals. None threw. The line is asserted rather than merely written
    // so the facts that distinguish those outcomes cannot be dropped later.
    final h = await harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);

    final previous = Diagnostics.instance;
    final records = <LogRecord>[];
    Diagnostics.instance = Diagnostics(echoToConsole: false);
    AppLogger.initialize(onRecord: records.add);
    addTearDown(() {
      Diagnostics.instance = previous;
      AppLogger.initialize();
    });

    final result = await h.container
        .read(sessionLauncherProvider)
        .launch(
          SessionLaunchRequest(
            repository: repository(),
            installation: agentInstallation(agentId: 'roverCli'),
            title: 'Rover run',
            purpose: SessionPurpose.newSession,
          ),
        );

    final line = records
        .where((r) => r.loggerName == 'sessions.launch')
        .map((r) => r.message)
        .join('\n');
    expect(line, contains(result.session.id));
    expect(line, contains('agent=roverCli'));
    expect(line, contains('pane=${result.paneId}'));
    // The four facts whose absence made the bugs invisible.
    expect(line, contains('mode='));
    expect(line, contains('resumed='));
    expect(line, contains('conversation='));
    expect(line, contains('mcp='));
  });

  // --- restarting to apply a permission mode ---------------------------------

  test('a restart replaces the agent with one under the new mode', () async {
    final h = await harness(
      settings: const Settings().withPermissions(
        'roverCli',
        const AgentPermissions(existingSessions: askStored),
      ),
    );
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    final launcher = h.container.read(sessionLauncherProvider);
    final terminals = h.container.read(
      terminalSessionsControllerProvider.notifier,
    );

    final started = await launcher.launch(
      SessionLaunchRequest(
        repository: repository(),
        installation: agentInstallation(agentId: 'roverCli'),
        title: 'Continue',
        purpose: SessionPurpose.existingSession,
        resumeExternalSessionId: 'external-1',
      ),
    );
    final id = started.session.id;
    final firstPane = started.paneId!;
    expect(terminals.instanceFor(firstPane)!.agentLaunch!.arguments, [
      '--mode',
      'ask',
      '--continue',
      'external-1',
    ]);

    // Exactly what the chip does: write the row, then ask for the restart.
    launcher.setPermissionMode(id, bypassSelection);
    final restarted = await launcher.restartSession(id);

    // One session, not two. A restart that minted a second row would leave the
    // tree drawing both and the double-writer check choosing between them.
    expect(restarted.session.id, id);
    expect(
      h.container
          .read(sessionsDataProvider)
          .getAllByExternalSessionId('external-1'),
      hasLength(1),
    );
    expect(
      h.container.read(sessionsDataProvider).getById(id)!.status,
      SessionStatus.running,
    );

    // A different process, and the old one is gone rather than detached: this
    // is an end, not a tab being closed.
    expect(restarted.paneId, isNot(firstPane));
    expect(terminals.instanceFor(firstPane), isNull);

    // And the whole point — the new flags are on a command line, which is the
    // only place any of these CLIs reads a permission policy from.
    expect(terminals.instanceFor(restarted.paneId!)!.agentLaunch!.arguments, [
      '--bypass',
      '--continue',
      'external-1',
    ]);
  });

  test('a restart keeps a session following the default', () async {
    final h = await harness(
      settings: const Settings().withPermissions(
        'roverCli',
        const AgentPermissions(existingSessions: bypassStored),
      ),
    );
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    final launcher = h.container.read(sessionLauncherProvider);

    final started = await launcher.launch(
      SessionLaunchRequest(
        repository: repository(),
        installation: agentInstallation(agentId: 'roverCli'),
        title: 'Continue',
        purpose: SessionPurpose.existingSession,
        resumeExternalSessionId: 'external-2',
      ),
    );
    final id = started.session.id;
    expect(
      h.container.read(sessionsDataProvider).getById(id)!.permissionMode,
      isNull,
    );

    final restarted = await launcher.restartSession(id);

    // The restart resolves a mode to put on the command line, and the trap is
    // writing that resolution back: the session would silently stop tracking
    // the Settings default, which is the half of the owner's report that says
    // "changing the default moved nothing".
    expect(
      h.container.read(sessionsDataProvider).getById(id)!.permissionMode,
      isNull,
    );
    expect(
      h.container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(restarted.paneId!)!
          .agentLaunch!
          .arguments,
      ['--bypass', '--continue', 'external-2'],
    );
  });

  test('a restart is refused when the CLI has named no conversation', () async {
    final h = await harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    final launcher = h.container.read(sessionLauncherProvider);

    // Rover takes no `--session-id`, so like Codex it has no conversation id
    // until something discovers one — the ordinary state of a fresh session.
    final started = await launcher.launch(
      SessionLaunchRequest(
        repository: repository(),
        installation: agentInstallation(agentId: 'roverCli'),
        title: 'Rover run',
        purpose: SessionPurpose.newSession,
      ),
    );
    final id = started.session.id;
    expect(
      h.container.read(sessionsDataProvider).getById(id)!.externalSessionId,
      isNull,
    );

    await expectLater(
      launcher.restartSession(id),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('new conversation'),
        ),
      ),
    );

    // The refusal costs nothing: relaunching without an id would come up on a
    // blank conversation wearing this row's title, so the only safe answer is
    // to leave the agent that has the history running.
    expect(launcher.livePaneFor(id), started.paneId);
    expect(
      h.container.read(sessionsDataProvider).getById(id)!.status,
      SessionStatus.running,
    );
  });

  group('a working directory whose environment row is gone', () {
    /// A session recorded in a distribution that has since been removed. Both
    /// launch surfaces resolve where the agent runs through the one resolver,
    /// so neither can invent its own sentence for it.
    const gone = EnvironmentPath(
      environmentId: 'wsl:Gone',
      path: '/home/me/app',
    );

    Matcher saysSoAndNamesTheId() => throwsA(
      isA<StateError>().having(
        (e) => e.message,
        'message',
        'Unknown environment: ${gone.environmentId}',
      ),
    );

    test('refuses a pane launch', () async {
      final h = await harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      await expectLater(
        h.container
            .read(sessionLauncherProvider)
            .launch(
              SessionLaunchRequest(
                repository: repository(),
                workingDirectory: gone,
                installation: agentInstallation(agentId: 'roverCli'),
                title: 'Rover run',
                purpose: SessionPurpose.newSession,
              ),
            ),
        saysSoAndNamesTheId(),
      );
    });

    test('refuses an external-terminal launch, in the same words', () async {
      final h = await harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      await expectLater(
        h.container
            .read(sessionLauncherProvider)
            .launch(
              SessionLaunchRequest(
                repository: repository(),
                workingDirectory: gone,
                installation: agentInstallation(agentId: 'roverCli'),
                title: 'Rover run',
                purpose: SessionPurpose.newSession,
                surface: SessionSurface.external,
              ),
            ),
        saysSoAndNamesTheId(),
      );
    });
  });
}
