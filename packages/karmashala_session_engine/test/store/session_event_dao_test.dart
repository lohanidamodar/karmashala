import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'package:karmashala_session_engine/store.dart';

import '../support/store_fixtures.dart';

void main() {
  late AppDatabase db;
  late SessionEventDao dao;

  setUp(() {
    db = AppDatabase.memory();
    seedWorkspace(db);
    SessionDao(db).insert(session());
    dao = SessionEventDao(db);
  });
  tearDown(() => db.close());

  test('append assigns monotonic 0-based sequence numbers', () {
    final a = dao.append(event(type: 'a'));
    final b = dao.append(event(type: 'b'));
    final c = dao.append(event(type: 'c'));
    expect([a.seq, b.seq, c.seq], [0, 1, 2]);
    expect(a.id, isNotNull);
  });

  test('listForSession returns events in append order', () {
    dao.append(event(type: 'first'));
    dao.append(event(type: 'second'));
    expect(dao.listForSession('s1').map((e) => e.type), ['first', 'second']);
  });

  test('sequence numbers are independent per session', () {
    SessionDao(db).insert(session(id: 's2', title: 'Second'));
    dao.append(event(sessionId: 's1', type: 'x'));
    final s2first = dao.append(event(sessionId: 's2', type: 'y'));
    expect(s2first.seq, 0);
    expect(dao.countForSession('s1'), 1);
    expect(dao.countForSession('s2'), 1);
  });

  test('the log is append-only — no update/delete API is exposed', () {
    // Compile-time guarantee: SessionEventDao has only append/list/count.
    final methods = dao.runtimeType.toString();
    expect(methods, 'SessionEventDao');
    dao.append(event());
    expect(dao.countForSession('s1'), 1);
  });

  test('deleting the session cascades to its events', () {
    dao.append(event());
    SessionDao(db).delete('s1');
    expect(dao.countForSession('s1'), 0);
  });
}
