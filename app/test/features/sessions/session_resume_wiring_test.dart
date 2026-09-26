import 'package:karmashala_store/database.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/sessions/application/session_actions.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_working_directory.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/resume.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/workspace_mirror.dart';
import '../../support/permission_fixtures.dart';
import '../terminal/fake_instance.dart';

/// Stand-ins for the two verified behaviours, so the tests exercise the
/// *capability* rather than a hard-coded agent id.
///
/// Claude Code 2.1.251 permits a second process on one conversation; Codex 0.151
/// refuses with an flock on `~/.codex/thread-writer-locks/<thread>.lock`. Which
/// CLI is which is data in the registry, and these two rows are that data.
const _sharing = AgentDescriptor(
  id: 'sharing',
  displayName: 'Sharing Agent',
  binaries: AgentBinaries(windows: ['sharing'], posix: ['sharing']),
  launch: AgentLaunchSpec(
    permission: testPermissionSupport,
    interactiveResume: AgentResume.flag('--resume'),
    allowsConcurrentResume: true,
  ),
);

const _exclusive = AgentDescriptor(
  id: 'exclusive',
  displayName: 'Exclusive Agent',
  binaries: AgentBinaries(windows: ['exclusive'], posix: ['exclusive']),
  launch: AgentLaunchSpec(
    permission: testPermissionSupport,
    interactiveResume: AgentResume.subcommand('resume'),
    // Left at the default — the point of the default.
  ),
);

/// Records what would have been handed to an external terminal, so a test can
/// tell "refused" from "launched" without spawning anything.
class _RecordingTerminals extends SystemTerminalService {
  _RecordingTerminals() : super(_DeadRunner());

  final launches = <List<String>>[];
  final directories = <String?>[];

  @override
  Future<void> launch(
    SystemTerminal terminal, {
    required List<String> command,
    String? workingDirectory,
  }) async {
    launches.add(command);
    directories.add(workingDirectory);
  }
}

class _DeadRunner implements CommandRunner {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('no process should be started');
}

class _StaticSettings extends SettingsController {
  @override
  Settings build() => const Settings();
}

const _terminal = SystemTerminal(
  kind: SystemTerminalKind.windowsTerminal,
  label: 'Windows Terminal',
  executable: 'wt.exe',
);

typedef Harness = ({
  ProviderContainer container,
  AppDatabase db,
  _RecordingTerminals terminals,
  FakeDataServer server,
});

Future<Harness> harness(
  AgentDescriptor agent, {
  Set<String> missingDirectories = const {},
}) async {
  final db = AppDatabase.memory();
  final server = FakeDataServer()..mirrorInto(db);
  server.environmentRows.upsert(windowsEnv());
  server.projectRows.insert(project());
  server.repositoryRows.insert(repository());
  server.installationRows.insert(agentInstallation(agentId: agent.id));

  final terminals = _RecordingTerminals();
  final container = ProviderContainer(
    overrides: [
      await server.override(),
      ...fakeTerminalOverrides(database: db),
      clockProvider.overrideWithValue(FixedClock(testTime)),
      idGeneratorProvider.overrideWithValue(SequentialIdGenerator('s-')),
      agentRegistryProvider.overrideWithValue(
        AgentRegistry([DataOnlyAgentAdapter(agent)]),
      ),
      settingsControllerProvider.overrideWith(_StaticSettings.new),
      systemTerminalServiceProvider.overrideWithValue(terminals),
      // The filesystem seam: nothing under `C:\src\demo` exists on a test
      // machine, so the default would call every recorded directory gone.
      sessionDirectoryPresentProvider.overrideWithValue(
        (directory) => !missingDirectories.contains(directory.path),
      ),
    ],
  );
  return (container: container, db: db, terminals: terminals, server: server);
}

/// Starts a session in a pane and pins its CLI id — the join between an imported
/// entry and one of our rows.
Future<String> startLive(
  Harness h,
  AgentDescriptor agent, {
  String? externalId = 'ext-1',
}) async {
  final launched = await h.container
      .read(sessionLauncherProvider)
      .launch(
        SessionLaunchRequest(
          repository: repository(),
          installation: agentInstallation(agentId: agent.id),
          title: 'Live work',
          purpose: SessionPurpose.newSession,
        ),
      );
  if (externalId != null) {
    h.container
        .read(sessionsDataProvider)
        .updateExternalSessionId(launched.session.id, externalId);
  }
  return launched.session.id;
}

ImportedSession imported(AgentDescriptor agent) => ImportedSession(
  id: 'i1',
  repositoryId: 'r1',
  cli: agent.id,
  externalId: 'ext-1',
  environmentId: 'windows',
  filePath: '/store/rollout-ext-1.jsonl',
  storeHome: '/store',
  isSubagent: false,
  preview: 'earlier work',
  createdAt: testTime,
);

void main() {
  group('the launcher answers the capability question once', () {
    test('for every agent it knows, and false for one it does not', () async {
      final h = await harness(_sharing);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      final launcher = h.container.read(sessionLauncherProvider);

      expect(launcher.allowsConcurrentResume('sharing'), isTrue);
      expect(launcher.allowsConcurrentResume('never-heard-of-it'), isFalse);
      expect(launcher.agentDisplayName('sharing'), 'Sharing Agent');
      // An unrecognised agent still gets a name to put in a sentence.
      expect(
        launcher.agentDisplayName('never-heard-of-it'),
        'never-heard-of-it',
      );
    });

    test('knowing we host it by either of the session\'s two names', () async {
      final h = await harness(_exclusive);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      final liveId = await startLive(h, _exclusive);
      final launcher = h.container.read(sessionLauncherProvider);

      expect(launcher.hostedLive(sessionId: liveId), isTrue);
      expect(launcher.hostedLive(externalSessionId: 'ext-1'), isTrue);
      expect(launcher.hostedLive(externalSessionId: 'someone-else'), isFalse);
      expect(launcher.hostedLive(), isFalse);
    });
  });

  group('reattaching wins wherever it is on offer', () {
    for (final agent in [_sharing, _exclusive]) {
      test('${agent.id}: resuming a session we host reopens it', () async {
        final h = await harness(agent);
        addTearDown(h.db.close);
        addTearDown(h.container.dispose);

        final liveId = await startLive(h, agent);
        final action = h.container
            .read(sessionLauncherProvider)
            .resumeActionForConversation(
              agentId: agent.id,
              externalSessionId: 'ext-1',
            );
        expect(action, ResumeAction.reattach);

        final resumed = await h.container
            .read(sessionActionsProvider)
            .resumeImported(imported(agent));

        // Instant, keeps the scrollback, cannot fail — better than a second
        // process even where a second process is allowed.
        expect(resumed, liveId);
        expect(
          h.container.read(sessionsDataProvider).getByRepository('r1'),
          hasLength(1),
        );
      });
    }
  });

  group('handing a live conversation to a terminal we do not own', () {
    test('is allowed when the agent permits it — the Claude case', () async {
      final h = await harness(_sharing);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      final liveId = await startLive(h, _sharing);
      final actions = h.container.read(sessionActionsProvider);

      // Two terminals listening to one conversation is exactly the thing that
      // is being enabled here, so neither call may throw.
      await actions.openSessionInSystemTerminal(liveId, _terminal);
      await actions.openInSystemTerminal(imported(_sharing), _terminal);

      // Both were handed to the terminal rather than refused. (The command
      // itself is `resumeCommandLine`'s business and is covered there; what
      // matters here is that two launches happened and neither threw.)
      expect(h.terminals.launches, hasLength(2));
      for (final command in h.terminals.launches) {
        expect(command.first, endsWith('claude.exe'));
      }
    });

    test('is refused when the agent forbids it — the Codex case', () async {
      final h = await harness(_exclusive);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      final liveId = await startLive(h, _exclusive);
      final actions = h.container.read(sessionActionsProvider);

      await expectLater(
        actions.openSessionInSystemTerminal(liveId, _terminal),
        throwsA(
          isA<SessionAlreadyRunning>()
              .having((e) => e.sessionId, 'sessionId', liveId)
              .having((e) => e.title, 'title', 'Live work')
              .having(
                (e) => e.toString(),
                'message',
                allOf(
                  contains('Live work'),
                  contains('Exclusive Agent'),
                  contains('start a new session'),
                  // Never the CLI's own words.
                  isNot(contains('-32600')),
                  isNot(contains('JSON')),
                ),
              ),
        ),
      );
      await expectLater(
        actions.openInSystemTerminal(imported(_exclusive), _terminal),
        throwsA(isA<SessionAlreadyRunning>()),
      );

      // The decisive property: nothing was spawned to die on the user's screen.
      expect(h.terminals.launches, isEmpty);
    });

    test('is refused for a native session with no CLI id yet', () async {
      // Codex will not accept a session id, so our row carries none until one is
      // discovered. A guard that only joined on the external id let every native
      // Codex session straight through.
      final h = await harness(_exclusive);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      final liveId = await startLive(h, _exclusive, externalId: null);
      expect(
        h.container
            .read(sessionsDataProvider)
            .getById(liveId)!
            .externalSessionId,
        isNull,
      );

      await expectLater(
        h.container
            .read(sessionActionsProvider)
            .openSessionInSystemTerminal(liveId, _terminal),
        throwsA(isA<SessionAlreadyRunning>()),
      );
      expect(h.terminals.launches, isEmpty);
    });

    test('is allowed once nothing of ours is running it', () async {
      final h = await harness(_exclusive);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      final liveId = await startLive(h, _exclusive);
      h.container
          .read(terminalSessionsControllerProvider.notifier)
          .endSession(
            h.container.read(sessionsDataProvider).getById(liveId)!.paneId!,
          );

      await h.container
          .read(sessionActionsProvider)
          .openSessionInSystemTerminal(liveId, _terminal);
      expect(h.terminals.launches, hasLength(1));
    });
  });

  group('the launcher backstop', () {
    test('lets a permitted second process through, and records it', () async {
      final h = await harness(_sharing);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      await startLive(h, _sharing);
      final second = await h.container
          .read(sessionLauncherProvider)
          .launch(
            SessionLaunchRequest(
              repository: repository(),
              installation: agentInstallation(agentId: 'sharing'),
              title: 'Second listener',
              purpose: SessionPurpose.existingSession,
              resumeExternalSessionId: 'ext-1',
            ),
          );

      // Two of our rows on one conversation, which is what the agent allows.
      expect(
        h.container.read(sessionsDataProvider).getByRepository('r1'),
        hasLength(2),
      );
      expect(second.session.externalSessionId, 'ext-1');
      final launch = h.container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(second.paneId!)!
          .agentLaunch!;
      expect(launch.arguments, ['--mode', 'ask', '--resume', 'ext-1']);
    });

    test('refuses a forbidden one before anything is written', () async {
      final h = await harness(_exclusive);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      await startLive(h, _exclusive);
      await expectLater(
        h.container
            .read(sessionLauncherProvider)
            .launch(
              SessionLaunchRequest(
                repository: repository(),
                installation: agentInstallation(agentId: 'exclusive'),
                title: 'Second writer',
                purpose: SessionPurpose.existingSession,
                resumeExternalSessionId: 'ext-1',
              ),
            ),
        throwsA(isA<SessionAlreadyRunning>()),
      );
      expect(
        h.container.read(sessionsDataProvider).getByRepository('r1'),
        hasLength(1),
      );
    });

    test('does not stand in the way of an unrelated conversation', () async {
      final h = await harness(_exclusive);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      await startLive(h, _exclusive);
      final other = await h.container
          .read(sessionLauncherProvider)
          .launch(
            SessionLaunchRequest(
              repository: repository(),
              installation: agentInstallation(agentId: 'exclusive'),
              title: 'Different thread',
              purpose: SessionPurpose.existingSession,
              resumeExternalSessionId: 'ext-2',
            ),
          );
      expect(other.session.externalSessionId, 'ext-2');
    });
  });

  group('a session opens where it was actually running', () {
    const subdirectory = r'C:\src\demo\app\packages\ui';
    const elsewhere = EnvironmentPath(
      environmentId: 'windows',
      path: subdirectory,
    );

    /// An adopted row: the CLI's id, a recorded directory, and no pane.
    void adopted(Harness h) {
      h.server.sessionRows.insert(
        session(
          id: 'adopted-1',
          title: 'Adopted',
          workingDirectory: elsewhere,
        ).copyWith(externalSessionId: 'ext-1'),
      );
    }

    test('an external terminal starts in the recorded directory', () async {
      final h = await harness(_exclusive);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      adopted(h);

      await h.container
          .read(sessionActionsProvider)
          .openSessionInSystemTerminal('adopted-1', _terminal);

      expect(h.terminals.directories.single, subdirectory);
    });

    test('the copied resume command cds where the agent ran', () async {
      final h = await harness(_exclusive);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      adopted(h);

      final command = h.container
          .read(sessionActionsProvider)
          .nativeResumeShellCommand('adopted-1');

      expect(command, contains(subdirectory));
    });

    test(
      'a directory that has gone away falls back to the repository',
      () async {
        // The resume must still happen. A recorded folder can be missing for
        // reasons that have nothing to do with the conversation — an unmounted
        // drive, a deleted scratch folder — and refusing would be worse than
        // starting one level up.
        final h = await harness(
          _exclusive,
          missingDirectories: const {subdirectory},
        );
        addTearDown(h.db.close);
        addTearDown(h.container.dispose);
        adopted(h);

        await h.container
            .read(sessionActionsProvider)
            .openSessionInSystemTerminal('adopted-1', _terminal);

        expect(h.terminals.directories.single, repository().path.path);
        // And the row still remembers where it ran: the folder may come back.
        expect(
          h.container
              .read(sessionsDataProvider)
              .getById('adopted-1')!
              .workingDirectory,
          elsewhere,
        );
      },
    );
  });

  group('a WSL row whose distribution is gone', () {
    /// CLAUDE.md 17's failure, at the two surfaces that hand a command to a
    /// terminal we do not own: a row that says "WSL" and no longer says which
    /// distribution used to build a `wsl.exe` line naming none. Both go through
    /// the one resolver now, so both refuse with its words instead.
    const words = 'WSL environment wsl:Ubuntu has no distribution name';

    /// A repository filed under a WSL environment that has lost its
    /// distribution name.
    void broken(Harness h) {
      mirroredServer(h.db).environmentRows.upsert(
        ExecutionEnvironment(
          id: 'wsl:Ubuntu',
          kind: EnvironmentKind.wsl,
          name: 'Ubuntu',
          createdAt: testTime,
        ),
      );
      h.server.repositoryRows.insert(
        repository(id: 'r2', environmentId: 'wsl:Ubuntu', path: '/home/me/app'),
      );
    }

    Matcher saysSo() =>
        throwsA(isA<StateError>().having((e) => e.message, 'message', words));

    test(
      'an imported entry refuses rather than spelling a broken line',
      () async {
        final h = await harness(_sharing);
        addTearDown(h.db.close);
        addTearDown(h.container.dispose);
        broken(h);

        await expectLater(
          h.container
              .read(sessionActionsProvider)
              .openInSystemTerminal(
                ImportedSession(
                  id: 'i2',
                  repositoryId: 'r2',
                  cli: _sharing.id,
                  externalId: 'ext-2',
                  environmentId: 'wsl:Ubuntu',
                  filePath: '/store/rollout-ext-2.jsonl',
                  storeHome: '/store',
                  isSubagent: false,
                  preview: 'earlier work',
                  createdAt: testTime,
                ),
                _terminal,
              ),
          saysSo(),
        );
        expect(h.terminals.launches, isEmpty);
      },
    );

    test('and one of our own sessions refuses in the same words', () async {
      final h = await harness(_sharing);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      broken(h);
      h.server.sessionRows.insert(
        session(
          id: 'n2',
          repositoryId: 'r2',
          title: 'Adopted',
        ).copyWith(externalSessionId: 'ext-2'),
      );

      await expectLater(
        h.container
            .read(sessionActionsProvider)
            .openSessionInSystemTerminal('n2', _terminal),
        saysSo(),
      );
      expect(h.terminals.launches, isEmpty);
    });
  });
}
