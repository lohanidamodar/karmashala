import 'package:karmashala_store/database.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/discovery.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/stream.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/git/application/worktree_service.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_engine.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala/src/features/sessions/data/session_event_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_repository_dao.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/permission_fixtures.dart';

/// An agent that exists only as data: a registry entry with **no `AgentKind`
/// member**, so nothing about it is hardcoded anywhere in the app.
const _rover = AgentDescriptor(
  id: 'roverCli',
  displayName: 'Rover CLI',
  binaries: AgentBinaries(windows: ['rover'], posix: ['rover']),
  launch: AgentLaunchSpec(
    baseArguments: ['--headless'],
    permission: testPermissionSupport,
    resume: AgentResume.flag('--continue'),
  ),
);

const _registry = AgentRegistry([_rover]);

/// [selection] resolved against Rover's own declared modes — the step the
/// caller that holds the descriptor performs before any adapter sees a launch.
ResolvedPermission _permission(PermissionSelection selection) =>
    ResolvedPermission.of(_rover.launch.permission, selection);

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

      // 3. SETTINGS — it can be the default agent and hold its own permissions,
      //    stored in *its own* vocabulary rather than a shared enum's.
      final settings = Settings(defaultAgent: stored.agentId).withPermissions(
        stored.agentId,
        const AgentPermissions(newSessions: acceptEditsStored),
      );
      final restoredSettings = Settings.fromJson(settings.toJson());
      expect(restoredSettings.defaultAgent, 'roverCli');
      expect(
        restoredSettings.permissionsFor('roverCli').newSessions,
        acceptEditsStored,
      );
      // And that stored string resolves back to a mode this agent really has.
      expect(
        _rover.launch.permission.resolveStored(acceptEditsStored),
        acceptEditsSelection,
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
        permission: _permission(acceptEditsSelection),
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
    AgentLaunch launch(PermissionSelection selection, String? resume) =>
        AgentLaunch(
          workingDirectory: repository().path,
          installation: agentInstallation(agentId: 'roverCli'),
          permission: ResolvedPermission.of(
            descriptor.launch.permission,
            selection,
          ),
          resumeSessionId: resume,
        );

    expect(genericLaunchArgs(descriptor.launch, launch(askSelection, null)), [
      '--headless',
      '--mode',
      'ask',
    ]);
    expect(
      genericLaunchArgs(descriptor.launch, launch(acceptEditsSelection, null)),
      ['--headless', '--mode', 'acceptEdits'],
    );
    expect(
      genericLaunchArgs(descriptor.launch, launch(bypassSelection, 'x1')),
      ['--headless', '--bypass', '--continue', 'x1'],
    );
  });

  test('the registry labels it without a hardcoded name', () {
    expect(_registry.displayNameFor('roverCli'), 'Rover CLI');
  });
}
