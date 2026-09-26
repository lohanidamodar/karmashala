import 'package:karmashala_store/database.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala/src/features/sessions/application/session_actions.dart';
import 'package:karmashala/src/features/sessions/application/session_working_directory.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/permission_fixtures.dart';
import '../terminal/fake_instance.dart';

/// Every surface that hands a user a "continue this conversation" command must
/// build it from the agent's own descriptor.
///
/// The bug these tests pin: `resumeCommandLine`/`shellCommandLine` chose their
/// resume arguments with `switch (cli) { 'claudeCode' => …, 'codex' => …, _ =>
/// [] }`, twenty lines under a `permissionArgsFor` that reads the registry
/// properly. Every other agent therefore got a command line with **no resume
/// arguments at all** — which is not a command that fails, it is a command that
/// silently starts a brand-new conversation wearing the old session's name and
/// loses the user's work.
///
/// So the two things asserted here are the two halves of the fix: an agent that
/// declares a resume convention gets it, and an agent that declares none is
/// refused **in words** rather than handed something that looks right.

/// Antigravity's shape: one flag for both launches. Not the built-in row, so
/// the assertion is about descriptor data being read rather than about a
/// second id being added to the switch.
const _conversational = AgentDescriptor(
  id: 'conversational',
  displayName: 'Conversational Agent',
  binaries: AgentBinaries(windows: ['conv'], posix: ['conv']),
  launch: AgentLaunchSpec(
    permission: testPermissionSupport,
    interactiveResume: AgentResume.flag('--conversation'),
    allowsConcurrentResume: true,
  ),
);

/// An agent with no command-line resume convention at all — the default, and
/// the case that must end in a sentence rather than in a fresh conversation.
const _silent = AgentDescriptor(
  id: 'silent',
  displayName: 'Silent Agent',
  binaries: AgentBinaries(windows: ['silent'], posix: ['silent']),
  launch: AgentLaunchSpec(
    permission: testPermissionSupport,
    // interactiveResume left at its default: unsupported.
  ),
);

class _RecordingTerminals extends SystemTerminalService {
  _RecordingTerminals() : super(_DeadRunner());

  final launches = <List<String>>[];

  @override
  Future<void> launch(
    SystemTerminal terminal, {
    required List<String> command,
    String? workingDirectory,
  }) async {
    launches.add(command);
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
});

Harness harness(AgentDescriptor agent) {
  final db = AppDatabase.memory();
  ExecutionEnvironmentDao(db).upsert(windowsEnv());
  ProjectDao(db).insert(project());
  RepositoryDao(db).insert(repository());
  AgentInstallationDao(
    db,
  ).insert(agentInstallation(agentId: agent.id, path: r'C:\bin\agent.exe'));
  SessionDao(db).insert(session(id: 'n1', title: 'Native work'));
  SessionDao(db).updateExternalSessionId('n1', 'ext-1');
  ImportedSessionDao(db).insertIfAbsent(_imported(agent));

  final terminals = _RecordingTerminals();
  final container = ProviderContainer(
    overrides: [
      ...fakeTerminalOverrides(database: db),
      clockProvider.overrideWithValue(FixedClock(testTime)),
      idGeneratorProvider.overrideWithValue(SequentialIdGenerator('s-')),
      agentRegistryProvider.overrideWithValue(
        AgentRegistry([DataOnlyAgentAdapter(agent)]),
      ),
      settingsControllerProvider.overrideWith(_StaticSettings.new),
      systemTerminalServiceProvider.overrideWithValue(terminals),
      sessionDirectoryPresentProvider.overrideWithValue((_) => true),
    ],
  );
  return (container: container, db: db, terminals: terminals);
}

ImportedSession _imported(AgentDescriptor agent) => ImportedSession(
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

Matcher _refusesToStartSomethingNew(String displayName) => throwsA(
  isA<StateError>().having(
    (e) => e.message,
    'message',
    allOf(contains(displayName), contains('ext-1'), contains('start a new')),
  ),
);

void main() {
  group('an agent that declares a resume convention gets it', () {
    test('the imported "copy command" carries the declared flag', () {
      final h = harness(_conversational);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      expect(
        h.container
            .read(sessionActionsProvider)
            .resumeShellCommand(_imported(_conversational)),
        // Quoted per token: these harness sessions live in the `windows`
        // environment, whose copied command is PowerShell.
        contains("'--conversation' 'ext-1'"),
      );
    });

    test('the native "copy command" carries it too', () {
      final h = harness(_conversational);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      expect(
        h.container.read(sessionActionsProvider).nativeResumeShellCommand('n1'),
        contains("'--conversation' 'ext-1'"),
      );
    });

    test('and a session recorded in another environment gets that shell', () {
      // The repository is Windows; this session actually runs in a worktree
      // inside a WSL distribution. The copied line has to be spelled for the
      // shell that opens *in the working directory* — naming a POSIX path in a
      // PowerShell `Set-Location` would be as wrong as the reverse, which is
      // the bug that started this: one syntax was emitted for every
      // environment in the app.
      final h = harness(_conversational);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      ExecutionEnvironmentDao(h.db).upsert(wslEnv());
      SessionDao(h.db).insert(
        session(
          id: 'n2',
          title: 'Worktree work',
          workingDirectory: const EnvironmentPath(
            environmentId: 'wsl:Ubuntu',
            path: '/home/me/wt',
          ),
        ),
      );
      SessionDao(h.db).updateExternalSessionId('n2', 'ext-2');

      final line = h.container
          .read(sessionActionsProvider)
          .nativeResumeShellCommand('n2');
      expect(line, startsWith('cd /home/me/wt && '));
      expect(line, contains('--conversation ext-2'));
      expect(line, isNot(contains('Set-Location')));
    });

    test('and so does the external-terminal open', () async {
      final h = harness(_conversational);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      await h.container
          .read(sessionActionsProvider)
          .openSessionInSystemTerminal('n1', _terminal);

      expect(
        h.terminals.launches.single,
        containsAllInOrder(['--conversation', 'ext-1']),
      );
    });
  });

  group('an agent that declares none is refused in words', () {
    test('the imported "copy command" refuses', () {
      final h = harness(_silent);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      expect(
        () => h.container
            .read(sessionActionsProvider)
            .resumeShellCommand(_imported(_silent)),
        _refusesToStartSomethingNew('Silent Agent'),
      );
    });

    test('the native "copy command" refuses', () {
      final h = harness(_silent);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      expect(
        () => h.container
            .read(sessionActionsProvider)
            .nativeResumeShellCommand('n1'),
        _refusesToStartSomethingNew('Silent Agent'),
      );
    });

    test('the imported external-terminal open refuses, launching nothing', () {
      final h = harness(_silent);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      expect(
        () => h.container
            .read(sessionActionsProvider)
            .openInSystemTerminal(_imported(_silent), _terminal),
        _refusesToStartSomethingNew('Silent Agent'),
      );
      expect(h.terminals.launches, isEmpty);
    });

    test(
      'the native external-terminal open refuses, launching nothing',
      () async {
        final h = harness(_silent);
        addTearDown(h.db.close);
        addTearDown(h.container.dispose);

        await expectLater(
          h.container
              .read(sessionActionsProvider)
              .openSessionInSystemTerminal('n1', _terminal),
          _refusesToStartSomethingNew('Silent Agent'),
        );
        expect(h.terminals.launches, isEmpty);
      },
    );

    test('but a *new* session command is not refused', () async {
      // The third copy button goes through the same decision, and the honest
      // answer for it is "nothing to refuse": it names no conversation, so it
      // cannot be mistaken for continuing one.
      final h = harness(_silent);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      expect(
        await h.container
            .read(sessionActionsProvider)
            .newSessionShellCommand('p1'),
        contains(r'C:\bin\agent.exe'),
      );
    });
  });

  test('a copied command refuses an environment the workspace has lost', () {
    // No process starts here — this only spells a line — but the *shell* it is
    // spelled for is the environment's, so an environment nobody can name
    // cannot be guessed at. Same resolver, same words as the launch paths.
    final h = harness(_conversational);
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);

    expect(
      () => h.container
          .read(sessionActionsProvider)
          .resumeShellCommand(
            ImportedSession(
              id: 'i2',
              repositoryId: 'r1',
              cli: _conversational.id,
              externalId: 'ext-1',
              environmentId: 'wsl:Gone',
              filePath: '/store/rollout-ext-1.jsonl',
              storeHome: '/store',
              isSubagent: false,
              preview: 'earlier work',
              createdAt: testTime,
            ),
          ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'Unknown environment: wsl:Gone',
        ),
      ),
    );
  });
}
