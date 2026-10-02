import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

final _t0 = DateTime.utc(2026, 10, 2, 12);

/// A row whose agent runs inside the server and ends with it is never
/// `unknown`: an end with no code and nobody asking — the server stopping —
/// and a row found still claiming to run at start are both `completed`. Every
/// other rule stands: a code says what it says, a close is a cancel, an
/// ending is kept.
void main() {
  late AppDatabase db;
  late SessionDao dao;
  late HostedSessionStatusKeeper keeper;

  setUp(() {
    db = AppDatabase.memory();
    db.execute('PRAGMA foreign_keys = OFF;');
    db.execute(
      'INSERT INTO execution_environments (id, kind, name, created_at) '
      'VALUES (?, ?, ?, ?);',
      ['win', 'windowsNative', 'win', '$_t0'],
    );
    db.execute(
      'INSERT INTO repositories '
      '(id, project_id, name, environment_id, path, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?);',
      ['local', 'p1', 'local', 'win', '/src/local', '$_t0'],
    );
    dao = SessionDao(db);
    keeper = keeperOver(
      db,
      // Decided per row — at the server by the installation's adapter.
      endsWithServer: (session) => session.agentInstallationId == 'acp',
    );
  });
  tearDown(() async {
    await keeper.dispose();
    db.close();
  });

  void insert(String id, String installation, {SessionStatus? status}) =>
      dao.insert(
        Session(
          id: id,
          repositoryId: 'local',
          agentInstallationId: installation,
          title: 'Work',
          useWorktree: false,
          status: status ?? SessionStatus.running,
          createdAt: _t0,
        ),
      );

  SessionLifecycleEvent exited(
    String id, {
    int? exitCode,
    String? reason,
    bool endedByClose = false,
  }) => SessionLifecycleEvent(
    hostSessionId: hostSessionIdOf(id),
    kind: SessionLifecycleKind.exited,
    exitCode: exitCode,
    reason: reason,
    endedByClose: endedByClose,
    observedAt: _t0,
  );

  SessionStatus statusOf(String id) => dao.getById(id)!.status;

  test('an exit with no code, not asked for, completes a row that ends with '
      'the server and loses sight of one that does not', () {
    insert('acp', 'acp');
    insert('pty', 'pty');

    keeper.applyEvent(exited('acp', reason: 'host stopped'));
    keeper.applyEvent(exited('pty', reason: 'host stopped'));

    expect(statusOf('acp'), SessionStatus.completed);
    expect(statusOf('pty'), SessionStatus.unknown);
  });

  test('a row not held at start is completed when it ends with the server, '
      'unknown otherwise', () {
    insert('acp', 'acp');
    insert('pty', 'pty');
    insert('held', 'acp');

    final changes = keeper.markUnheld(
      heldHostSessionIds: {hostSessionIdOf('held')},
    );

    expect(statusOf('acp'), SessionStatus.completed);
    expect(statusOf('pty'), SessionStatus.unknown);
    expect(statusOf('held'), SessionStatus.running);
    expect(changes.map((c) => '${c.sessionId} ${c.to.name}'), [
      'acp completed',
      'pty unknown',
    ]);
  });

  test(
    'a code, a close and a recorded ending are read as they always were',
    () {
      insert('zero', 'acp');
      insert('three', 'acp');
      insert('closed', 'acp');
      insert('over', 'acp', status: SessionStatus.failed);

      keeper.applyEvent(exited('zero', exitCode: 0));
      keeper.applyEvent(exited('three', exitCode: 3));
      keeper.applyEvent(exited('closed', endedByClose: true));
      keeper.markUnheld(heldHostSessionIds: const {});

      expect(statusOf('zero'), SessionStatus.completed);
      expect(statusOf('three'), SessionStatus.failed);
      expect(statusOf('closed'), SessionStatus.cancelled);
      expect(statusOf('over'), SessionStatus.failed);
    },
  );
}
