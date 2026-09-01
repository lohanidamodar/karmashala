import 'dart:convert';

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/agents/data/fake_agent_adapter.dart';
import 'package:karmashala/src/features/agents/domain/agent_adapter.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/settings/domain/permission_mode.dart';
import 'package:karmashala/src/features/git/application/worktree_service.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_engine.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_event_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_repository_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session_event_types.dart';
import 'package:karmashala/src/features/sessions/domain/session_status.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

void main() {
  late AppDatabase db;
  late SessionDao sessionDao;
  late SessionEventDao eventDao;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    sessionDao = SessionDao(db);
    eventDao = SessionEventDao(db);
  });
  tearDown(() => db.close());

  SessionEngine buildEngine({AdapterResolver? resolver}) => SessionEngine(
    sessionDao: sessionDao,
    eventDao: eventDao,
    sessionRepositoryDao: SessionRepositoryDao(db),
    worktreeService: WorktreeService(
      runnerFactory: FakeCommandRunnerFactory(),
      environmentDao: ExecutionEnvironmentDao(db),
    ),
    resolveAdapter: resolver ?? (agentId) => FakeAgentAdapter(agentId: agentId),
    clock: FixedClock(testTime),
    ids: SequentialIdGenerator(),
  );

  Future<void> waitForEvents(String sessionId, int n) async {
    for (var i = 0; i < 200; i++) {
      if (eventDao.countForSession(sessionId) >= n) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('timed out waiting for $n events in $sessionId');
  }

  List<String> typesOf(String sessionId) =>
      eventDao.listForSession(sessionId).map((e) => e.type).toList();

  String textOf(SessionEventDao dao, String sessionId, int seq) =>
      jsonDecode(dao.listForSession(sessionId)[seq].payload)['text'] as String;

  test('start records session.started then the agent greeting', () async {
    final engine = buildEngine();
    final session = await engine.start(
      repository: repository(),
      installation: agentInstallation(),
      title: 'Work',
    );
    await waitForEvents(session.id, 2);

    expect(typesOf(session.id), [
      SessionEventTypes.sessionStarted,
      SessionEventTypes.agentMessage,
    ]);
    expect(textOf(eventDao, session.id, 1), 'Fake agent ready.');
    expect(sessionDao.getById(session.id)!.status, SessionStatus.running);
    expect(engine.isActive(session.id), isTrue);
  });

  test('sendMessage records the user message and the agent reply', () async {
    final engine = buildEngine();
    final session = await engine.start(
      repository: repository(),
      installation: agentInstallation(),
      title: 'Work',
    );
    await waitForEvents(session.id, 2);

    await engine.sendMessage(session.id, 'hello');
    await waitForEvents(session.id, 4);

    expect(typesOf(session.id).sublist(2), [
      SessionEventTypes.userMessage,
      SessionEventTypes.agentMessage,
    ]);
    expect(textOf(eventDao, session.id, 2), 'hello');
    expect(textOf(eventDao, session.id, 3), 'Echo: hello');
  });

  test('two sessions run concurrently and independently', () async {
    final engine = buildEngine();
    final s1 = await engine.start(
      repository: repository(),
      installation: agentInstallation(),
      title: 'One',
    );
    final s2 = await engine.start(
      repository: repository(),
      installation: agentInstallation(),
      title: 'Two',
    );
    await waitForEvents(s1.id, 2);
    await waitForEvents(s2.id, 2);

    await engine.sendMessage(s1.id, 'only s1');
    await waitForEvents(s1.id, 4);

    expect(eventDao.countForSession(s1.id), 4);
    expect(eventDao.countForSession(s2.id), 2); // untouched
    expect(engine.activeSessionIds.toSet(), {s1.id, s2.id});
  });

  test('stop marks the session cancelled and ends it', () async {
    final engine = buildEngine();
    final session = await engine.start(
      repository: repository(),
      installation: agentInstallation(),
      title: 'Work',
    );
    await waitForEvents(session.id, 2);

    final done = engine.whenDone(session.id);
    await engine.stop(session.id);
    await done;

    expect(sessionDao.getById(session.id)!.status, SessionStatus.cancelled);
    expect(typesOf(session.id).last, SessionEventTypes.sessionCancelled);
    expect(engine.isActive(session.id), isFalse);
  });

  test('start links the primary repository and any additional ones', () async {
    // A second repository in the same project to attach.
    RepositoryDao(db).insert(repository(id: 'r2', name: 'api'));
    final engine = buildEngine();
    final s = await engine.start(
      repository: repository(),
      installation: agentInstallation(),
      title: 'Multi',
      additionalRepositories: [repository(id: 'r2', name: 'api')],
    );

    final links = SessionRepositoryDao(db).linksFor(s.id);
    expect(links.first.isPrimary, isTrue);
    expect(links.map((l) => l.repositoryId).toSet(), {'r1', 'r2'});
  });

  test('forwards permission mode and resume id to the adapter', () async {
    final adapter = _CapturingAdapter();
    final engine = buildEngine(resolver: (_) => adapter);
    await engine.start(
      repository: repository(),
      installation: agentInstallation(),
      title: 'Resume',
      permissionMode: PermissionMode.bypass,
      resumeSessionId: 'ext-123',
    );
    expect(adapter.captured!.permissionMode, PermissionMode.bypass);
    expect(adapter.captured!.resumeSessionId, 'ext-123');
  });

  test('a self-completing agent marks the session completed', () async {
    final engine = buildEngine(
      resolver: (agentId) =>
          FakeAgentAdapter(agentId: agentId, autoComplete: true),
    );
    final session = await engine.start(
      repository: repository(),
      installation: agentInstallation(),
      title: 'Work',
    );
    final done = engine.whenDone(session.id);
    await done;

    expect(sessionDao.getById(session.id)!.status, SessionStatus.completed);
    expect(typesOf(session.id).last, SessionEventTypes.sessionCompleted);
  });
}

/// Captures the [AgentLaunch] it receives, for asserting what the engine passed.
class _CapturingAdapter implements AgentAdapter {
  AgentLaunch? captured;

  @override
  String get agentId => AgentIds.claudeCode;

  @override
  AgentSession start(AgentLaunch launch) {
    captured = launch;
    return FakeAgentSession('hi');
  }
}
