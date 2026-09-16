/// The production wiring of `workspace.list` and `session.start`, driven
/// through the protocol against a real container: the same DAOs, the same
/// registry, and the same [SessionLauncher] the desktop's own New session
/// dialog writes through.
library;

import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala_remote/host.dart';
import 'package:karmashala/src/features/remote/application/remote_bindings.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/permission_fixtures.dart';
import '../terminal/fake_instance.dart';
import 'fake_bindings.dart';

/// An agent whose CLI takes an opening message and declares three modes of its
/// own — so the phone is offered a real vocabulary rather than a hypothesis.
const _rover = AgentDescriptor(
  id: 'roverCli',
  displayName: 'Rover CLI',
  binaries: AgentBinaries(windows: ['rover'], posix: ['rover']),
  launch: AgentLaunchSpec(
    baseArguments: ['--headless'],
    prompt: AgentPromptSupport.positional(),
    permission: testPermissionSupport,
  ),
);

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late List<({FrameType type, String? id, Map<String, Object?> payload})> sent;
  late HostSessionApi api;
  var seq = 0;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db)
      ..upsert(windowsEnv())
      ..upsert(wslEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation(agentId: 'roverCli'));
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('s-')),
        agentRegistryProvider.overrideWithValue(
          const AgentRegistry([_rover]),
        ),
        settingsControllerProvider.overrideWith(_StaticSettings.new),
        // The folder probe touches disk in production; this test is about the
        // listing, not about what exists on the machine running it.
        remoteFolderMissingProvider.overrideWithValue((path) => false),
        remoteCheckoutBranchProvider.overrideWithValue((path) => 'main'),
      ],
    );
    sent = [];
    seq = 0;
    api = HostSessionApi(
      device: fakeDevice(),
      bindings: container.read(remoteHostBindingsProvider),
      send: (type, {id, payload = const {}}) async {
        sent.add((type: type, id: id, payload: payload));
        return true;
      },
    );
  });

  tearDown(() {
    container.dispose();
    db.close();
  });

  Future<void> request(
    FrameType type, {
    Map<String, Object?> payload = const {},
  }) => api.handleEnvelope(
    Envelope.of(type, seq: seq++, id: 'q$seq', payload: payload),
  );

  Future<List<RemoteWorkspaceProject>> workspace() async {
    await request(FrameType.workspaceList);
    final projects = sent.last.payload['projects']! as List;
    return [
      for (final entry in projects)
        RemoteWorkspaceProject.fromJson(entry as Map<String, Object?>),
    ];
  }

  group('workspace.list', () {
    test('reports the projects, checkouts and agents that exist', () async {
      final projects = await workspace();

      expect(projects.map((p) => p.projectId), ['p1']);
      final checkout = projects.single.checkouts.single;
      expect(checkout.repositoryId, 'r1');
      expect(checkout.name, 'app');
      expect(checkout.branch, 'main');
      expect(checkout.subPath, 'app');
      final agent = checkout.agents.single;
      expect(agent.installationId, 'a1');
      expect(agent.name, 'Rover CLI');
      expect(agent.version, '1.0.0');
      expect(agent.acceptsOpeningMessage, isTrue);
    });

    test('an agent installed elsewhere is not offered here', () async {
      AgentInstallationDao(db).insert(
        agentInstallation(
          id: 'a2',
          agentId: 'roverCli',
          environmentId: 'wsl:Ubuntu',
          path: '/usr/bin/rover',
        ),
      );

      final projects = await workspace();

      expect(
        projects.single.checkouts.single.agents.map((a) => a.installationId),
        ['a1'],
        reason: 'the Windows checkout can only run what is installed there',
      );
    });

    test('offers the agent own modes, safest first, and marks the dangerous '
        'one', () async {
      final agent = (await workspace()).single.checkouts.single.agents.single;

      // The agent's own selections, in the agent's own vocabulary. There is
      // no shared three-mode menu left to offer, so nothing here is a mode
      // this agent cannot be put into.
      expect(agent.permissionModes.map((m) => m.mode), [
        askStored,
        acceptEditsStored,
        bypassStored,
      ]);
      expect(agent.permissionModes.every((m) => m.selectable), isTrue);
      final accept = agent.permissionModes[1];
      // Minted host-side with the rung's borrowed name in front of the CLI's
      // own word, so the phone shows the pairing without knowing rungs exist.
      expect(accept.label, 'Build · Accept edits');
      expect(
        accept.summary,
        contains('Auto-approves edits'),
        reason: "the agent's own words about the mode reach the phone",
      );
      expect(agent.permissionModes.last.dangerous, isTrue);
    });

    test('an agent whose modes are unknown sends one row that says so',
        () async {
      // Installed, but nothing in the registry declares what it can be put
      // into. The phone gets one unselectable row rather than an empty menu.
      AgentInstallationDao(db).insert(
        agentInstallation(id: 'a2', agentId: 'mysteryCli'),
      );

      final agents = (await workspace()).single.checkouts.single.agents;
      final mystery = agents.firstWhere((a) => a.installationId == 'a2');

      expect(mystery.permissionModes.single.selectable, isFalse);
      expect(
        mystery.permissionModes.single.summary,
        contains('mysteryCli'),
        reason: 'the agent is named, so the limit is not blamed on the app',
      );
    });

    test('preselects the desktop own new-session mode, never one of its own', () async {
      final agent = (await workspace()).single.checkouts.single.agents.single;

      expect(agent.defaultMode, askStored);
    });

    test('names the environment each checkout lives in', () async {
      // The reported case: one project, the same repository checked out under
      // Windows and inside a WSL distribution. Two rows called "app" whose
      // only difference used to be a path the phone's owner had to decode.
      RepositoryDao(db).insert(
        repository(
          id: 'r2',
          environmentId: 'wsl:Ubuntu',
          path: '/home/me/demo/app',
        ),
      );

      final projects = await workspace();

      expect(
        projects.single.checkouts.map((c) => c.environmentName),
        ['WSL · Ubuntu', 'Windows'],
        reason: 'sorted by path, and each says where it lives',
      );
      expect(projects.single.environmentName, 'Windows');
    });

    test('an environment with nothing to call it is left unnamed', () async {
      // A WSL row whose distribution was never recorded and whose name is
      // blank: there is no honest word for it, and "WSL · " is not one.
      ExecutionEnvironmentDao(db).upsert(
        ExecutionEnvironment(
          id: 'wsl:',
          kind: EnvironmentKind.wsl,
          name: '',
          createdAt: testTime,
        ),
      );
      RepositoryDao(db).insert(
        repository(id: 'r2', environmentId: 'wsl:', path: '/srv/demo/web'),
      );

      final unnamed = (await workspace()).single.checkouts.firstWhere(
        (c) => c.repositoryId == 'r2',
      );

      expect(
        unnamed.environmentName,
        isNull,
        reason: 'the phone falls back to the path rather than invent a name',
      );
    });

    test('a project with no checkout is absent, not an empty offer', () async {
      ProjectDao(db).insert(project(id: 'p2', name: 'Empty', path: r'C:\none'));

      expect((await workspace()).map((p) => p.projectId), ['p1']);
    });
  });

  group('session.start', () {
    Future<void> start({
      String requestId = 'k1',
      String repositoryId = 'r1',
      String installationId = 'a1',
      String permissionMode = askStored,
      String? title,
      String? message,
    }) => request(
      FrameType.sessionStart,
      payload: {
        'requestId': requestId,
        'repositoryId': repositoryId,
        'installationId': installationId,
        'permissionMode': permissionMode,
        'title': ?title,
        'message': ?message,
      },
    );

    test('writes a real session row through the launcher', () async {
      await start(title: 'From the phone', message: 'begin');

      expect(sent.last.type, FrameType.result);
      final started = RemoteSessionStarted.fromJson(sent.last.payload);
      final session = SessionDao(db).getById(started.sessionId);
      expect(session, isNotNull);
      expect(session!.title, 'From the phone');
      expect(session.repositoryId, 'r1');
      expect(session.agentInstallationId, 'a1');
      expect(
        session.permissionMode,
        askStored,
        reason: 'the launcher stamps the mode, and the answer reports it',
      );
      expect(started.permissionMode, askStored);
    });

    test('starts under the mode the phone was told to pick', () async {
      await start(permissionMode: bypassStored);

      final started = RemoteSessionStarted.fromJson(sent.last.payload);
      expect(
        SessionDao(db).getById(started.sessionId)!.permissionMode,
        bypassStored,
      );
    });

    test('refuses a mode this agent cannot be put into', () async {
      // A real mode — Claude Code's bypass — but not one Rover has. A mode
      // spelled in another CLI's vocabulary is refused in this agent's own
      // terms rather than launched under its default.
      await start(permissionMode: claudeBypassStored);

      expect(sent.last.type, FrameType.error);
      expect(sent.last.payload['code'], ErrorCode.badRequest.wire);
      expect(sent.last.payload['message'], contains('Rover CLI'));
      expect(SessionDao(db).getAll(), isEmpty);
    });

    test('refuses a mode that does not exist here', () async {
      await start(permissionMode: 'yolo');

      expect(sent.last.payload['code'], ErrorCode.badRequest.wire);
      expect(sent.last.payload['message'], contains('yolo'));
    });

    test('refuses a checkout the desktop no longer holds', () async {
      await start(repositoryId: 'gone');

      expect(sent.last.payload['code'], ErrorCode.notFound.wire);
      expect(SessionDao(db).getAll(), isEmpty);
    });

    test('refuses an agent installed somewhere else', () async {
      AgentInstallationDao(db).insert(
        agentInstallation(
          id: 'a2',
          agentId: 'roverCli',
          environmentId: 'wsl:Ubuntu',
          path: '/usr/bin/rover',
        ),
      );

      await start(installationId: 'a2');

      expect(sent.last.payload['code'], ErrorCode.badRequest.wire);
      expect(
        sent.last.payload['message'],
        contains('not installed where that checkout lives'),
      );
      expect(SessionDao(db).getAll(), isEmpty);
    });

    test('the same key twice leaves one row behind', () async {
      await start(title: 'Once');
      await start(title: 'Once');

      expect(SessionDao(db).getAll(), hasLength(1));
      expect(sent.last.payload['replayed'], isTrue);
    });
  });
}

class _StaticSettings extends SettingsController {
  @override
  Settings build() => const Settings();
}
