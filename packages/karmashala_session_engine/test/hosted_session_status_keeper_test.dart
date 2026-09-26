import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';
import 'package:karmashala_session_engine/store.dart';

final _t0 = DateTime.utc(2026, 9, 25, 12);

void main() {
  late AppDatabase db;
  late SessionDao dao;
  late HostedSessionStatusKeeper keeper;
  late List<SessionLifecycleChange> written;

  setUp(() {
    db = AppDatabase.memory();
    db.execute('PRAGMA foreign_keys = OFF;');
    final now = _t0.toIso8601String();
    for (final (id, kind) in [('win', 'windowsNative'), ('ssh:h1', 'ssh')]) {
      db.execute(
        'INSERT INTO execution_environments (id, kind, name, created_at) '
        'VALUES (?, ?, ?, ?);',
        [id, kind, id, now],
      );
    }
    for (final (id, env) in [('local', 'win'), ('remote', 'ssh:h1')]) {
      db.execute(
        'INSERT INTO repositories '
        '(id, project_id, name, environment_id, path, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?);',
        [id, 'p1', id, env, '/src/$id', now],
      );
    }
    dao = SessionDao(db);
    keeper = keeperOver(db);
    written = [];
    keeper.changes.listen(written.add);
  });
  tearDown(() async {
    await keeper.dispose();
    db.close();
  });

  void insert(
    String id, {
    SessionStatus status = SessionStatus.running,
    String repositoryId = 'local',
  }) => dao.insert(
    Session(
      id: id,
      repositoryId: repositoryId,
      agentInstallationId: 'a1',
      title: 'Work',
      useWorktree: false,
      status: status,
      createdAt: _t0,
    ),
  );

  SessionStatus statusOf(String id) => dao.getById(id)!.status;

  test('a snapshot and the events after it are written to the rows they '
      'name, and each write is announced', () {
    insert('s1', status: SessionStatus.unknown);
    keeper.applySnapshot([
      SessionFacts(
        hostSessionId: hostSessionIdOf('s1'),
        state: HostSessionState.running,
        observedAt: _t0,
      ),
      // A host session no row names is nobody's to write.
      SessionFacts(
        hostSessionId: 'shell_1',
        state: HostSessionState.running,
        observedAt: _t0,
      ),
    ]);
    expect(statusOf('s1'), SessionStatus.running);

    keeper.applyEvent(
      SessionLifecycleEvent(
        hostSessionId: hostSessionIdOf('s1'),
        kind: SessionLifecycleKind.exited,
        exitCode: 0,
        observedAt: _t0.add(const Duration(seconds: 1)),
      ),
    );
    expect(statusOf('s1'), SessionStatus.completed);
    expect(
      [for (final c in written) '${c.sessionId} ${c.to.name}'],
      ['s1 running', 's1 completed'],
    );
  });

  test('a live claim on this machine the host does not hold is unknown; one '
      'it holds, one a client runs, an SSH one and an ending are left', () {
    insert('held');
    insert('lost');
    insert('in-app');
    insert('remote', repositoryId: 'remote');
    insert('done', status: SessionStatus.completed);

    final changes = keeper.markUnheld(
      heldHostSessionIds: {hostSessionIdOf('held')},
      runByClient: {'in-app'},
    );

    expect([for (final c in changes) c.sessionId], ['lost']);
    expect(statusOf('lost'), SessionStatus.unknown);
    expect(statusOf('held'), SessionStatus.running);
    expect(statusOf('in-app'), SessionStatus.running);
    expect(statusOf('remote'), SessionStatus.running);
    expect(statusOf('done'), SessionStatus.completed);
  });

  test('sessionRunsOnThisMachine reads the row\'s environment', () {
    insert('here');
    insert('there', repositoryId: 'remote');
    insert('nowhere', repositoryId: 'missing');
    expect(sessionRunsOnThisMachine(db, dao.getById('here')!), isTrue);
    expect(sessionRunsOnThisMachine(db, dao.getById('there')!), isFalse);
    expect(sessionRunsOnThisMachine(db, dao.getById('nowhere')!), isFalse);
  });
}
