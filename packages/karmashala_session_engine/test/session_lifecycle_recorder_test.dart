import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

final _t0 = DateTime.utc(2026, 9, 25, 12);

void main() {
  late AppDatabase db;
  late SessionDao dao;
  late SessionLifecycleRecorder recorder;

  setUp(() {
    db = AppDatabase.memory();
    // The rows' repository and installation are not what is under test.
    db.execute('PRAGMA foreign_keys = OFF;');
    dao = SessionDao(db);
    recorder = SessionLifecycleRecorder(dao);
  });
  tearDown(() async {
    await recorder.dispose();
    db.close();
  });

  void insert(String id, SessionStatus status, {DateTime? archivedAt}) =>
      dao.insert(
        Session(
          id: id,
          repositoryId: 'r1',
          agentInstallationId: 'a1',
          title: 'Work',
          useWorktree: false,
          status: status,
          createdAt: _t0,
          archivedAt: archivedAt,
        ),
      );

  SessionFacts facts(
    String sessionId,
    HostSessionState state, {
    int? exitCode,
    String? reason,
    bool endedByClose = false,
    Duration after = Duration.zero,
  }) => SessionFacts(
    hostSessionId: hostSessionIdOf(sessionId),
    state: state,
    exitCode: exitCode,
    reason: reason,
    endedByClose: endedByClose,
    observedAt: _t0.add(after),
  );

  String? sessionIdOf(String hostId) =>
      sessionIdForHostId(hostId, dao.getAll().map((s) => s.id));

  SessionLifecycleChange? apply(SessionFacts f) =>
      recorder.apply(f, sessionIdOf: sessionIdOf);

  SessionStatus statusOf(String id) => dao.getById(id)!.status;

  test('writes the derived status and reports the change', () {
    insert('s1', SessionStatus.created);
    final emitted = <SessionLifecycleChange>[];
    recorder.changes.listen(emitted.add);

    final change = apply(facts('s1', HostSessionState.running));

    expect(statusOf('s1'), SessionStatus.running);
    expect(change!.sessionId, 's1');
    expect(change.from, SessionStatus.created);
    expect(change.to, SessionStatus.running);
    expect(emitted.single.to, SessionStatus.running);
  });

  test('writes nothing when the status already says it', () {
    insert('s1', SessionStatus.running);
    final emitted = <SessionLifecycleChange>[];
    recorder.changes.listen(emitted.add);

    expect(apply(facts('s1', HostSessionState.running)), isNull);
    expect(emitted, isEmpty);
  });

  test('an exit code settles the row completed or failed', () {
    insert('ok', SessionStatus.running);
    insert('bad', SessionStatus.running);
    apply(facts('ok', HostSessionState.exited, exitCode: 0));
    apply(facts('bad', HostSessionState.exited, exitCode: 1));
    expect(statusOf('ok'), SessionStatus.completed);
    expect(statusOf('bad'), SessionStatus.failed);
  });

  test('an exit nobody saw makes a running row unknown', () {
    insert('s1', SessionStatus.running);
    apply(
      facts(
        's1',
        HostSessionState.exited,
        reason: 'host stopped while running',
      ),
    );
    expect(statusOf('s1'), SessionStatus.unknown);
  });

  test('an exit nobody saw does not undo an ending', () {
    for (final ended in [SessionStatus.completed, SessionStatus.failed]) {
      insert(ended.name, ended);
      expect(apply(facts(ended.name, HostSessionState.exited)), isNull);
      expect(statusOf(ended.name), ended);
    }
  });

  test('closed on request is cancelled, and a later exit keeps it', () {
    insert('s1', SessionStatus.running);
    apply(facts('s1', HostSessionState.closed, endedByClose: true));
    expect(statusOf('s1'), SessionStatus.cancelled);

    apply(facts('s1', HostSessionState.exited, exitCode: 143, after: _second));
    expect(statusOf('s1'), SessionStatus.cancelled);
  });

  test('a close on request is cancelled from its exit on: one write, never '
      'failed in between', () {
    insert('s1', SessionStatus.running);
    final written = [
      apply(
        facts(
          's1',
          HostSessionState.exited,
          exitCode: 143,
          endedByClose: true,
          after: _second,
        ),
      ),
      apply(
        facts(
          's1',
          HostSessionState.closed,
          exitCode: 143,
          endedByClose: true,
          after: _second * 2,
        ),
      ),
    ].nonNulls.map((change) => change.to);
    expect(written, [SessionStatus.cancelled]);
    expect(statusOf('s1'), SessionStatus.cancelled);
  });

  test('running again after an ending is running', () {
    insert('s1', SessionStatus.completed);
    apply(facts('s1', HostSessionState.running));
    expect(statusOf('s1'), SessionStatus.running);
  });

  test('idle already says the process runs', () {
    insert('s1', SessionStatus.idle);
    expect(apply(facts('s1', HostSessionState.running)), isNull);
    expect(statusOf('s1'), SessionStatus.idle);
  });

  test('never touches an archived row', () {
    insert('s1', SessionStatus.running, archivedAt: _t0);
    expect(apply(facts('s1', HostSessionState.exited, exitCode: 0)), isNull);
    expect(statusOf('s1'), SessionStatus.running);
  });

  test('a host session that is no row is ignored', () {
    expect(apply(facts('ghost', HostSessionState.running)), isNull);
  });

  test('a fact older than the last one applied is stale', () {
    insert('s1', SessionStatus.created);
    apply(facts('s1', HostSessionState.running, after: _second));
    expect(apply(facts('s1', HostSessionState.exited, exitCode: 0)), isNull);
    expect(statusOf('s1'), SessionStatus.running);
  });

  test('a snapshot applies each session it names', () {
    insert('a', SessionStatus.unknown);
    insert('b', SessionStatus.running);
    insert('c', SessionStatus.running);

    final changes = recorder.applySnapshot([
      facts('a', HostSessionState.running),
      facts('b', HostSessionState.exited, exitCode: 2),
      facts('c', HostSessionState.running),
    ], sessionIdOf: sessionIdOf);

    expect(changes.map((c) => (c.sessionId, c.to)), [
      ('a', SessionStatus.running),
      ('b', SessionStatus.failed),
    ]);
  });

  test('unseen by any host: a live row is unknown, an ending stays', () {
    insert('live', SessionStatus.running);
    insert('done', SessionStatus.completed);
    expect(recorder.recordUnseen('live')!.to, SessionStatus.unknown);
    expect(recorder.recordUnseen('done'), isNull);
    expect(statusOf('done'), SessionStatus.completed);
  });
}

const _second = Duration(seconds: 1);
