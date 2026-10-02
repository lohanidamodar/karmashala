import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

final _t0 = DateTime.utc(2026, 10, 2, 12);

/// A row whose agent runs inside the server is never `unknown`: the resolver
/// says what a host's silence means — here, as the server decides it, a
/// clean end (no host holding it at start, the server's own stop) is
/// `completed` and an end with no code for any other reason is `failed`.
/// Every other rule stands: a code says what it says, a close is a cancel,
/// an ending is kept, and a row the resolver leaves alone is `unknown`.
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
      // Decided per row — at the server by the installation's adapter — and
      // per reason, in the server's own vocabulary.
      resolveUnknown: (session, facts) {
        if (session.agentInstallationId != 'acp') return SessionStatus.unknown;
        if (facts == null || facts.reason == 'the host stopped') {
          return SessionStatus.completed;
        }
        return SessionStatus.failed;
      },
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

  test('an exit with no code is read by its reason for a row that ends with '
      'the server — the host\'s stop completes it, a refused start fails it '
      '— and loses sight of one that does not', () {
    insert('stopped', 'acp');
    insert('refused', 'acp');
    insert('pty', 'pty');

    keeper.applyEvent(exited('stopped', reason: 'the host stopped'));
    keeper.applyEvent(
      exited('refused', reason: 'Agent asks to be logged in first'),
    );
    keeper.applyEvent(exited('pty', reason: 'the host stopped'));

    expect(statusOf('stopped'), SessionStatus.completed);
    expect(statusOf('refused'), SessionStatus.failed);
    expect(statusOf('pty'), SessionStatus.unknown);
  });

  test('a failed start stays failed whichever write lands last', () {
    insert('refused', 'acp');

    keeper.applyEvent(exited('refused', reason: 'could not be started'));
    expect(statusOf('refused'), SessionStatus.failed);
    // The launcher's own write, before or after: the same word.
    dao.updateStatus('refused', SessionStatus.failed);
    expect(statusOf('refused'), SessionStatus.failed);

    insert('refused-late', 'acp');
    dao.updateStatus('refused-late', SessionStatus.failed);
    keeper.applyEvent(exited('refused-late', reason: 'could not be started'));
    expect(statusOf('refused-late'), SessionStatus.failed);
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
