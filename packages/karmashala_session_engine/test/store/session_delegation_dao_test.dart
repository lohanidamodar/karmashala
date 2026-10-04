import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// `session_delegations`: one row per async child, saying which of its
/// turns its parent awaits, so a restart can re-arm the push.
void main() {
  final t0 = DateTime.utc(2026, 10, 4, 12);
  late AppDatabase db;
  late SessionDelegationDao dao;

  SessionDelegation row(String child, {String parent = 'p'}) =>
      SessionDelegation(
        childSessionId: child,
        parentSessionId: parent,
        title: 'Task $child',
        agent: 'Codex',
        model: 'gpt-5',
        endOnAnswer: true,
        delegatedAt: t0,
        turn: 1,
        turnStartedAt: t0,
      );

  setUp(() {
    db = AppDatabase.memory();
    db.execute('PRAGMA foreign_keys = OFF;');
    dao = SessionDelegationDao(db);
  });
  tearDown(() => db.close());

  test('a delegation reads back as it was put', () {
    dao.put(row('c1'));
    final read = dao.byChild('c1')!;
    expect(read.parentSessionId, 'p');
    expect(read.title, 'Task c1');
    expect(read.agent, 'Codex');
    expect(read.model, 'gpt-5');
    expect(read.endOnAnswer, isTrue);
    expect(read.delegatedAt, t0);
    expect(read.turn, 1);
    expect(read.turnStartedAt, t0);
    expect(read.awaiting, isTrue);
  });

  test('a reported turn stops awaiting; only the turn reported is cleared', () {
    dao.put(row('c1'));
    expect(dao.turnReported('c1', turn: 2), isFalse);
    expect(dao.byChild('c1')!.awaiting, isTrue);
    expect(dao.turnReported('c1', turn: 1), isTrue);
    expect(dao.byChild('c1')!.awaiting, isFalse);
    expect(dao.awaiting(), isEmpty);
  });

  test('a follow-up awaits the next turn, from when it was sent', () {
    dao.put(row('c1'));
    dao.turnReported('c1', turn: 1);
    final later = t0.add(const Duration(minutes: 5));
    final next = dao.awaitNextTurn('c1', since: later)!;
    expect(next.turn, 2);
    expect(next.turnStartedAt, later);
    expect(dao.awaiting().map((d) => d.childSessionId), ['c1']);
  });

  test('a follow-up to no delegation is nothing', () {
    expect(dao.awaitNextTurn('nobody', since: t0), isNull);
  });

  test('removed, it is gone; a parent lists only its own', () {
    dao
      ..put(row('c1'))
      ..put(row('c2', parent: 'q'));
    expect(dao.forParent('p').map((d) => d.childSessionId), ['c1']);
    dao.remove('c1');
    expect(dao.byChild('c1'), isNull);
    expect(dao.awaiting().map((d) => d.childSessionId), ['c2']);
  });
}
