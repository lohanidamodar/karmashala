import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/process/command_runner.dart';
import 'package:chitragupta/src/features/agents/data/agent_discovery_service.dart';
import 'package:chitragupta/src/features/agents/data/agent_installation_dao.dart';
import 'package:chitragupta/src/features/agents/data/fake_agent_adapter.dart';
import 'package:chitragupta/src/features/agents/data/generic_agent_adapter.dart';
import 'package:chitragupta/src/features/agents/domain/agent_adapter.dart';
import 'package:chitragupta/src/features/agents/domain/agent_descriptor.dart';
import 'package:chitragupta/src/features/agents/domain/agent_installation.dart';
import 'package:chitragupta/src/features/agents/domain/agent_registry.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/git/application/worktree_service.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
import 'package:chitragupta/src/features/repositories/data/repository_dao.dart';
import 'package:chitragupta/src/features/sessions/application/session_engine.dart';
import 'package:chitragupta/src/features/sessions/data/session_dao.dart';
import 'package:chitragupta/src/features/sessions/data/session_event_dao.dart';
import 'package:chitragupta/src/features/sessions/data/session_repository_dao.dart';
import 'package:chitragupta/src/features/sessions/domain/session_status.dart';
import 'package:chitragupta/src/features/settings/domain/permission_mode.dart';
import 'package:chitragupta/src/features/settings/domain/settings.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// An agent that exists only as data: a registry entry with **no `AgentKind`
/// member**, so nothing about it is hardcoded anywhere in the app.
const _rover = AgentDescriptor(
  id: 'roverCli',
  displayName: 'Rover CLI',
  binaries: AgentBinaries(windows: ['rover'], posix: ['rover']),
  launch: AgentLaunchSpec(
    baseArguments: ['--headless'],
    permissionModes: {
      PermissionMode.ask: PermissionModeMapping.exact([]),
      PermissionMode.acceptEdits: PermissionModeMapping.exact(['--auto-edit']),
      PermissionMode.bypass: PermissionModeMapping.exact(['--trust-me']),
    },
    resume: AgentResume.flag('--continue'),
  ),
);

const _registry = AgentRegistry([_rover]);

void main() {
  test(
    'a descriptor with no AgentKind survives discovery to session',
    () async {
      // 1. DISCOVERY — probing finds it and it becomes a persistable
      //    installation. Loop 28 dropped it here.
      final runner = FakeCommandRunner(
        responder: (request) => CommandResult(
          exitCode: 0,
          stdout: request.executable == 'where'
              ? r'C:\bin\rover.exe'
              : 'v4.1.0',
          stderr: '',
        ),
      );
      final discovered = await AgentDiscoveryService(
        runner: runner,
        environment: windowsEnv(),
        ids: SequentialIdGenerator(),
        clock: FixedClock(testTime),
        registry: _registry,
      ).discover();

      expect(discovered.single.agentId, 'roverCli');
      expect(discovered.single.version, '4.1.0');
      expect(discovered.single.executable.path, r'C:\bin\rover.exe');

      // 2. PERSISTENCE + READ-BACK — the id is the stored key, unchanged.
      final db = AppDatabase.memory();
      addTearDown(db.close);
      ExecutionEnvironmentDao(db).upsert(windowsEnv());
      ProjectDao(db).insert(project());
      RepositoryDao(db).insert(repository());
      final installationDao = AgentInstallationDao(db)
        ..insert(discovered.single);
      final AgentInstallation stored = installationDao.getAll().single;

      expect(stored, discovered.single);
      expect(stored.agentId, 'roverCli');
      expect(
        installationDao
            .getByIdentity('roverCli', 'windows', r'C:\bin\rover.exe')!
            .id,
        stored.id,
      );

      // 3. SETTINGS — it can be the default agent and hold its own permissions.
      final settings = Settings(defaultAgent: stored.agentId).withPermissions(
        stored.agentId,
        const AgentPermissions(newSessions: PermissionMode.acceptEdits),
      );
      final restoredSettings = Settings.fromJson(settings.toJson());
      expect(restoredSettings.defaultAgent, 'roverCli');
      expect(
        restoredSettings.permissionsFor('roverCli').newSessions,
        PermissionMode.acceptEdits,
      );

      // 4. SESSION CREATION — the engine resolves the adapter by agent id.
      final resolved = <String>[];
      final engine = SessionEngine(
        sessionDao: SessionDao(db),
        eventDao: SessionEventDao(db),
        sessionRepositoryDao: SessionRepositoryDao(db),
        worktreeService: WorktreeService(
          runnerFactory: FakeCommandRunnerFactory(),
          environmentDao: ExecutionEnvironmentDao(db),
        ),
        resolveAdapter: (agentId) {
          resolved.add(agentId);
          return FakeAgentAdapter(agentId: agentId);
        },
        clock: FixedClock(testTime),
        ids: SequentialIdGenerator('s-'),
      );

      final session = await engine.start(
        repository: repository(),
        installation: stored,
        title: 'Rover run',
        permissionMode: PermissionMode.acceptEdits,
      );

      expect(resolved, ['roverCli']);
      expect(SessionDao(db).getById(session.id)!.status, SessionStatus.running);
      expect(
        SessionDao(db).getByRepository(repository().id).single.id,
        session.id,
      );
      await engine.stop(session.id);
    },
  );

  test('its launch arguments come from the descriptor, not from code', () {
    final descriptor = _registry.byId('roverCli')!;
    AgentLaunch launch(PermissionMode mode, String? resume) => AgentLaunch(
      workingDirectory: repository().path,
      installation: agentInstallation(agentId: 'roverCli'),
      permissionMode: mode,
      resumeSessionId: resume,
    );

    expect(
      genericLaunchArgs(descriptor.launch, launch(PermissionMode.ask, null)),
      ['--headless'],
    );
    expect(
      genericLaunchArgs(
        descriptor.launch,
        launch(PermissionMode.acceptEdits, null),
      ),
      ['--headless', '--auto-edit'],
    );
    expect(
      genericLaunchArgs(descriptor.launch, launch(PermissionMode.bypass, 'x1')),
      ['--headless', '--trust-me', '--continue', 'x1'],
    );
  });

  test('the registry labels it without a hardcoded name', () {
    expect(_registry.displayNameFor('roverCli'), 'Rover CLI');
  });
}
