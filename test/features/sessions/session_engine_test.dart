import 'dart:async';
import 'dart:convert';

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/stream.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/git/application/worktree_service.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_engine.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_event_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_repository_dao.dart';
import 'package:karmashala_session/session.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/permission_fixtures.dart';

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
      permission: ResolvedPermission.none,
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

  test('a spawn that throws leaves no runtime and marks the row failed', () async {
    final engine = buildEngine(
      resolver: (_) => _RefusingAdapter(),
    );
    await expectLater(
      engine.start(
        repository: repository(),
        installation: agentInstallation(),
        title: 'Work',
        permission: ResolvedPermission.none,
      ),
      throwsA(isA<StateError>()),
    );
    final row = sessionDao.getAll().single;
    expect(row.status, SessionStatus.failed);
    expect(engine.isActive(row.id), isFalse);
    // Nothing was registered, so a message is refused rather than "sent".
    await expectLater(engine.sendMessage(row.id, 'hi'), throwsA(isA<StateError>()));
  });

  test('a CLI that exits non-zero ends the session failed, not completed', () async {
    final engine = buildEngine(resolver: (_) => _ExitingAdapter());
    final session = await engine.start(
      repository: repository(),
      installation: agentInstallation(),
      title: 'Work',
      permission: ResolvedPermission.none,
    );
    await engine.whenDone(session.id);

    expect(sessionDao.getById(session.id)!.status, SessionStatus.failed);
    expect(typesOf(session.id), contains(SessionEventTypes.error));
    expect(typesOf(session.id).last, isNot(SessionEventTypes.sessionCompleted));
  });

  test('sendMessage records the user message and the agent reply', () async {
    final engine = buildEngine();
    final session = await engine.start(
      repository: repository(),
      installation: agentInstallation(),
      title: 'Work',
      permission: ResolvedPermission.none,
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
      permission: ResolvedPermission.none,
    );
    final s2 = await engine.start(
      repository: repository(),
      installation: agentInstallation(),
      title: 'Two',
      permission: ResolvedPermission.none,
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
      permission: ResolvedPermission.none,
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
      permission: ResolvedPermission.none,
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
      permission: ResolvedPermission.of(testPermissionSupport, bypassSelection),
      resumeSessionId: 'ext-123',
    );
    // The selection *and* the flags it resolved to, because the adapter is
    // handed both and cannot look either up.
    expect(adapter.captured!.permission.selection, bypassSelection);
    expect(adapter.captured!.permission.arguments, ['--bypass']);
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
      permission: ResolvedPermission.none,
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

/// A spawn that fails synchronously: a rotted executable path, a refused exec.
class _RefusingAdapter implements AgentAdapter {
  @override
  String get agentId => AgentIds.claudeCode;

  @override
  AgentSession start(AgentLaunch launch) => throw StateError('no such executable');
}

/// A CLI that starts, says why it is leaving, and exits 1 — a `--resume` of a
/// session the CLI no longer has.
class _ExitingAdapter implements AgentAdapter {
  @override
  String get agentId => AgentIds.claudeCode;

  @override
  AgentSession start(AgentLaunch launch) => _ExitingSession();
}

class _ExitingSession implements AgentSession {
  final _controller = StreamController<AgentEvent>();

  _ExitingSession() {
    _controller.add(
      AgentEvent(SessionEventTypes.error, {
        'message': 'claude exited with code 1',
        'exitCode': 1,
        'stderr': ['No conversation found with session ID'],
      }),
    );
    _controller.close();
  }

  @override
  Stream<AgentEvent> get events => _controller.stream;

  @override
  Future<void> send(String message) async {}

  @override
  Future<void> stop() async {}
}
