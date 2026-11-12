import 'dart:io';

import 'package:agent_cli/descriptors.dart' show AgentIds;
import 'package:agent_cli/discovery.dart' show AgentInstallation;
import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/agents/registered_project_trust.dart';
import 'package:karmashala_host/src/automations/hosted_agent_launcher.dart';
import 'package:karmashala_host/src/serve/server_features.dart';
import 'package:karmashala_remote/remote.dart' show Capability, CapabilitySet;
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// "Trust registered projects for agents": on unless the person turns it off,
/// and while on, a new conversation in a registered checkout has the folder
/// trusted for its agent before the agent starts. Never a folder Karmashala
/// does not know, never a resume.
void main() {
  final t0 = DateTime.utc(2026, 11, 12, 12);

  late Directory tmp;
  late String checkout;
  late String elsewhere;
  late AppDatabase db;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ks-project-trust');
    checkout = '${tmp.path}${Platform.pathSeparator}shop';
    elsewhere = '${tmp.path}${Platform.pathSeparator}loose';
    Directory(checkout).createSync();
    Directory(elsewhere).createSync();
    db = AppDatabase.memory();
    db.execute('PRAGMA foreign_keys = OFF;');
    db.execute(
      'INSERT INTO execution_environments (id, kind, name, created_at) '
      'VALUES (?, ?, ?, ?);',
      [
        'local',
        Platform.isWindows ? 'windowsNative' : 'localPosix',
        'Here',
        '$t0',
      ],
    );
    db.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      'created_at) VALUES (?, ?, ?, ?, ?, ?);',
      ['r1', 'p1', 'shop', 'local', checkout, '$t0'],
    );
    db.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      'executable_path, created_at, executable_by_user) '
      'VALUES (?, ?, ?, ?, ?, ?);',
      ['a1', AgentIds.claudeCode, 'local', '/bin/claude', '$t0', 1],
    );
  });

  tearDown(() {
    db.close();
    tmp.deleteSync(recursive: true);
  });

  void turn(bool enabled) => DataService(
    db,
    clock: () => t0,
  ).open((_) {}).handle(AgentsTrustRegisteredProjectsSet(enabled: enabled));

  group('the setting', () {
    test('is on with nothing stored, and a subscriber hears nothing', () {
      expect(db.readMetadata(kTrustRegisteredProjectsKey), isNull);
      expect(
        RegisteredProjectTrust(db, trust: (_, _) async => true).enabled,
        isTrue,
      );
      final greeted = <DataChanges>[];
      DataService(
        db,
        clock: () => t0,
      ).open(greeted.add).handle(const DataSubscribe());
      expect(
        greeted.expand((b) => b.changes),
        isNot(contains(isA<TrustRegisteredProjectsChanged>())),
      );
    });

    test('is turned off and on through its own method, told to every client '
        'and greeted while off', () {
      final service = DataService(db, clock: () => t0);
      final told = <DataChanges>[];
      service.open(told.add).handle(const DataSubscribe());
      final app = service.open((_) {});

      app.handle(const AgentsTrustRegisteredProjectsSet(enabled: false));
      expect(db.readMetadata(kTrustRegisteredProjectsKey), 'false');
      expect(
        told.expand((b) => b.changes),
        contains(
          isA<TrustRegisteredProjectsChanged>().having(
            (c) => c.enabled,
            'enabled',
            isFalse,
          ),
        ),
      );
      final greeted = <DataChanges>[];
      service.open(greeted.add).handle(const DataSubscribe());
      expect(
        greeted.expand((b) => b.changes),
        contains(isA<TrustRegisteredProjectsChanged>()),
      );

      app.handle(const AgentsTrustRegisteredProjectsSet(enabled: true));
      expect(
        trustsRegisteredProjects(db.readMetadata(kTrustRegisteredProjectsKey)),
        isTrue,
      );
    });

    test('is not a preference a client can write', () {
      expect(
        () => DataService(db, clock: () => t0)
            .open((_) {})
            .handle(PreferenceSet(kTrustRegisteredProjectsKey, 'false')),
        throwsA(
          isA<DataRefused>().having(
            (r) => r.code,
            'code',
            DataRefusalCode.reserved,
          ),
        ),
      );
    });

    test('a phone needs what starting a session needs', () {
      const request = AgentsTrustRegisteredProjectsSet(enabled: false);
      expect(
        phoneRefusal(request, grants: CapabilitySet.none),
        contains('start_session'),
      );
      expect(
        phoneRefusal(
          request,
          grants: CapabilitySet.of([Capability.startSession]),
        ),
        isNull,
      );
    });

    test('the wire carries it, and the server announces it', () {
      final decoded = DataRequest.fromJson(
        AgentsTrustRegisteredProjectsSet.name,
        const AgentsTrustRegisteredProjectsSet(
          enabled: false,
        ).argumentsToJson(),
      );
      expect((decoded as AgentsTrustRegisteredProjectsSet).enabled, isFalse);
      final change = DataChange.fromJson(
        const TrustRegisteredProjectsChanged(enabled: false).toJson(),
      );
      expect((change as TrustRegisteredProjectsChanged).enabled, isFalse);
      expect(
        kServerFeatures,
        contains(AgentsTrustRegisteredProjectsSet.feature),
      );
    });
  });

  group('which folders', () {
    late List<EnvironmentPath> trusted;
    late List<String> logged;
    late RegisteredProjectTrust projects;
    late AgentInstallation installation;

    setUp(() {
      installation = CheckoutRows(db).installation('a1')!;
      trusted = [];
      logged = [];
      projects = RegisteredProjectTrust(
        db,
        trust: (_, folder) async {
          trusted.add(folder);
          return true;
        },
        log: logged.add,
      );
    });

    test(
      'a registered checkout is trusted, however its end is spelled',
      () async {
        final spelled = Platform.isWindows
            ? '${checkout.toUpperCase()}\\'
            : '$checkout/';
        expect(
          await projects.trustForNewConversation(
            installation,
            EnvironmentPath(environmentId: 'local', path: spelled),
          ),
          isTrue,
        );
        expect(trusted, hasLength(1));
      },
    );

    test('a worktree a session of a project recorded is trusted', () async {
      final tree = '${tmp.path}${Platform.pathSeparator}tree';
      db.execute(
        'INSERT INTO sessions (id, repository_id, agent_installation_id, '
        'title, use_worktree, worktree_environment_id, worktree_path, status, '
        'created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);',
        ['s0', 'r1', 'a1', 'Tree', 1, 'local', tree, 'completed', '$t0'],
      );
      expect(
        await projects.trustForNewConversation(
          installation,
          EnvironmentPath(environmentId: 'local', path: tree),
        ),
        isTrue,
      );
    });

    test('an unregistered folder, or the checkout on another machine, is '
        'never trusted', () async {
      expect(
        await projects.trustForNewConversation(
          installation,
          EnvironmentPath(environmentId: 'local', path: elsewhere),
        ),
        isFalse,
      );
      expect(
        await projects.trustForNewConversation(
          installation,
          EnvironmentPath(environmentId: 'wsl-1', path: checkout),
        ),
        isFalse,
      );
      expect(trusted, isEmpty);
    });

    test('nothing is trusted while the setting is off', () async {
      turn(false);
      expect(
        await projects.trustForNewConversation(
          installation,
          EnvironmentPath(environmentId: 'local', path: checkout),
        ),
        isFalse,
      );
      expect(trusted, isEmpty);
    });

    test('a write that throws is logged and the launch goes on', () async {
      final failing = RegisteredProjectTrust(
        db,
        trust: (_, _) async => throw const FileSystemException('locked'),
        log: logged.add,
      );
      expect(
        await failing.trustForNewConversation(
          installation,
          EnvironmentPath(environmentId: 'local', path: checkout),
        ),
        isFalse,
      );
      expect(logged.single, contains('could not be marked trusted'));
    });
  });

  group('a launch', () {
    late FakePtyLauncher pty;
    late SessionRegistry registry;
    late List<(EnvironmentPath, int)> trusted;
    late HostedAgentLauncher launcher;
    late CheckoutRows rows;

    setUp(() {
      pty = FakePtyLauncher();
      registry = SessionRegistry(launcher: pty);
      trusted = [];
      rows = CheckoutRows(db);
      final projects = RegisteredProjectTrust(
        db,
        trust: (_, folder) async {
          trusted.add((folder, pty.started.length));
          return true;
        },
      );
      var ids = 0;
      launcher = HostedAgentLauncher(
        registry: registry,
        sessions: SessionDao(db),
        mcp: SessionMcpAccessPoint(mcp: null, configDirectory: tmp.path),
        now: () => t0,
        newId: () => 'new-${++ids}',
        hostEnvironment: const {},
        environmentOf: rows.environment,
        trustRegisteredProject: projects.trustForNewConversation,
        windows: false,
      );
    });

    tearDown(() async {
      for (final handle in pty.handles) {
        handle.finish(0);
      }
      await registry.shutdown();
    });

    HostedLaunch fresh({EnvironmentPath? workingDirectory}) => HostedLaunch(
      repository: rows.repository('r1')!,
      installation: rows.installation('a1')!,
      title: 'Work',
      workingDirectory: workingDirectory,
    );

    test('a new conversation in a registered project has it trusted before '
        'its agent starts', () async {
      await launcher.start(fresh());
      expect(trusted, [
        (EnvironmentPath(environmentId: 'local', path: checkout), 0),
      ]);
      expect(pty.started.single.workingDirectory, checkout);
    });

    test('with the setting off nothing is written', () async {
      turn(false);
      await launcher.start(fresh());
      expect(trusted, isEmpty);
      expect(pty.started, hasLength(1));
    });

    test('an unregistered working directory is never trusted', () async {
      await launcher.start(
        fresh(
          workingDirectory: EnvironmentPath(
            environmentId: 'local',
            path: elsewhere,
          ),
        ),
      );
      expect(trusted, isEmpty);
      expect(pty.started.single.workingDirectory, elsewhere);
    });

    test('a resume writes nothing', () async {
      SessionDao(db).insert(
        Session(
          id: 'old',
          repositoryId: 'r1',
          agentInstallationId: 'a1',
          title: 'Old',
          useWorktree: false,
          status: SessionStatus.completed,
          createdAt: t0,
          externalSessionId: 'conversation-1',
        ),
      );
      await launcher.start(
        HostedLaunch(
          repository: rows.repository('r1')!,
          installation: rows.installation('a1')!,
          title: 'Old',
          resuming: SessionDao(db).getById('old'),
        ),
      );
      expect(trusted, isEmpty);
      expect(pty.started, hasLength(1));
    });
  });
}
