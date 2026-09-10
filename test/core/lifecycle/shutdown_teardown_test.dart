import 'dart:async';

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/lifecycle/app_lifecycle.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/stream.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/git/application/worktree_service.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_engine.dart';
import 'package:karmashala/src/features/sessions/application/session_engine_provider.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_event_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_repository_dao.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala/src/features/ssh/application/ssh_providers.dart';
import 'package:karmashala/src/features/ssh/data/known_host_dao.dart';
import 'package:karmashala/src/features/ssh/data/ssh_connection_pool.dart';
import 'package:karmashala/src/features/ssh/data/ssh_host_dao.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// What quitting has to end, beyond the components the lifecycle owner builds
/// itself.
///
/// `ref.onDispose` takes a callback, not a future, so Riverpod starts a
/// teardown and immediately forgets it. That is fine for a field being nulled
/// and wrong for anything that ends a process or closes a socket: on quit,
/// `windowManager.destroy()` runs the moment the shutdown sequence returns.
/// Before Loop 65 the session engine had no teardown at all — `_finish` is
/// driven by the agent's own stream closing, which on quit never happens — so
/// the agent CLIs outlived the app that started them.
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

  SessionEngine buildEngine(AdapterResolver resolver) => SessionEngine(
    sessionDao: sessionDao,
    eventDao: eventDao,
    sessionRepositoryDao: SessionRepositoryDao(db),
    worktreeService: WorktreeService(
      runnerFactory: FakeCommandRunnerFactory(),
      environmentDao: ExecutionEnvironmentDao(db),
    ),
    resolveAdapter: resolver,
    clock: FixedClock(testTime),
    ids: SequentialIdGenerator(),
  );

  group('SessionEngine.dispose', () {
    test('stops every live agent and empties the runtimes', () async {
      final adapter = _RecordingAdapter();
      final engine = buildEngine((_) => adapter);
      final session = await engine.start(
        repository: repository(),
        installation: agentInstallation(),
        title: 'Work',
        permission: ResolvedPermission.none,
      );
      expect(engine.isActive(session.id), isTrue);
      final done = engine.whenDone(session.id)!;

      await engine.dispose();

      expect(adapter.sessions.single.stopped, isTrue);
      expect(engine.activeSessionIds, isEmpty);
      expect(engine.isActive(session.id), isFalse);
      // Anyone waiting on the run is released rather than left hanging.
      await done;
    });

    test('records nothing: the app ended, the session did not', () async {
      final adapter = _RecordingAdapter();
      final engine = buildEngine((_) => adapter);
      final session = await engine.start(
        repository: repository(),
        installation: agentInstallation(),
        title: 'Work',
        permission: ResolvedPermission.none,
      );
      final eventsBefore = eventDao.countForSession(session.id);

      await engine.dispose();

      expect(
        sessionDao.getById(session.id)!.status,
        SessionStatus.running,
        reason: 'a run that was interrupted by a quit was not cancelled',
      );
      expect(eventDao.countForSession(session.id), eventsBefore);
    });

    test('is idempotent', () async {
      final adapter = _RecordingAdapter();
      final engine = buildEngine((_) => adapter);
      await engine.start(
        repository: repository(),
        installation: agentInstallation(),
        title: 'Work',
        permission: ResolvedPermission.none,
      );

      await Future.wait([engine.dispose(), engine.dispose()]);
      await engine.dispose();

      expect(adapter.sessions.single.stopCalls, 1);
    });
  });

  group('the shutdown waits for what Riverpod drops', () {
    test('the session engine is stopped, and awaited', () async {
      final gate = Completer<void>();
      final adapter = _RecordingAdapter(gate: gate.future);
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          agentAdapterResolverProvider.overrideWithValue((_) => adapter),
        ],
      );
      final engine = container.read(sessionEngineProvider);
      await engine.start(
        repository: repository(),
        installation: agentInstallation(),
        title: 'Work',
        permission: ResolvedPermission.none,
      );
      final lifecycle = AppLifecycle(container);

      var finished = false;
      final shutdown = lifecycle.shutdown().whenComplete(() => finished = true);
      await pumpEventQueue();

      expect(
        finished,
        isFalse,
        reason: 'the agent process has not gone away yet',
      );

      gate.complete();
      await shutdown;

      expect(adapter.sessions.single.stopped, isTrue);
      expect(engine.activeSessionIds, isEmpty);
    });

    test('the SSH pool is closed, and awaited', () async {
      final gate = Completer<void>();
      final pool = _RecordingPool(
        hosts: SshHostDao(db),
        knownHosts: KnownHostDao(db),
        gate: gate.future,
      );
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sshConnectionPoolProvider.overrideWithValue(pool),
        ],
      );
      container.read(sshConnectionPoolProvider);
      final lifecycle = AppLifecycle(container);

      var finished = false;
      final shutdown = lifecycle.shutdown().whenComplete(() => finished = true);
      await pumpEventQueue();

      expect(finished, isFalse, reason: 'the sockets are still open');

      gate.complete();
      await shutdown;

      expect(pool.closed, isTrue);
    });
  });
}

/// An adapter whose sessions record being stopped, and can be made to take
/// their time about it.
class _RecordingAdapter implements AgentAdapter {
  _RecordingAdapter({this.gate});

  /// Held until this completes, standing in for a child process that does not
  /// die the instant it is asked to.
  final Future<void>? gate;

  final sessions = <_RecordingSession>[];

  @override
  String get agentId => 'fake';

  @override
  AgentSession start(AgentLaunch launch) {
    final session = _RecordingSession(gate);
    sessions.add(session);
    return session;
  }
}

class _RecordingSession implements AgentSession {
  _RecordingSession(this._gate);

  final Future<void>? _gate;
  final _controller = StreamController<AgentEvent>();

  bool stopped = false;
  int stopCalls = 0;

  @override
  Stream<AgentEvent> get events => _controller.stream;

  @override
  Future<void> send(String message) async {}

  @override
  Future<void> stop() async {
    stopCalls++;
    if (_gate != null) await _gate;
    stopped = true;
    if (!_controller.isClosed) await _controller.close();
  }
}

/// A pool whose close can be held open, so a test can see whether the shutdown
/// waits for it or merely starts it.
class _RecordingPool extends SshConnectionPool {
  _RecordingPool({
    required super.hosts,
    required super.knownHosts,
    required this.gate,
  });

  final Future<void> gate;
  bool closed = false;

  @override
  Future<void> closeAll() async {
    await gate;
    closed = true;
    await super.closeAll();
  }
}
