import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import '../support/store_fixtures.dart';

/// `session_handoffs`: one text per kind per session, replaced by the next
/// launch, consumed once, and cleared a day after it was used.
void main() {
  late AppDatabase db;
  late SessionHandoffDao dao;
  final t0 = DateTime.utc(2026, 10, 4, 12);

  setUp(() {
    db = AppDatabase.memory();
    seedWorkspace(db);
    SessionDao(db)
      ..insert(session())
      ..insert(session(id: 's2'));
    dao = SessionHandoffDao(db);
  });
  tearDown(() => db.close());

  SessionHandoff handoff(
    String sessionId, {
    HandoffKind kind = HandoffKind.opening,
    String text = 'line one\nline two',
    HandoffRoute route = HandoffRoute.typed,
    DateTime? at,
  }) => SessionHandoff(
    sessionId: sessionId,
    kind: kind,
    text: text,
    route: route,
    createdAt: at ?? t0,
  );

  test('a put is read back whole, unconsumed', () {
    dao.put(handoff('s1'));
    final read = dao.get('s1', HandoffKind.opening)!;
    expect(read.text, 'line one\nline two');
    expect(read.route, HandoffRoute.typed);
    expect(read.createdAt, t0);
    expect(read.consumedAt, isNull);
    expect(dao.get('s1', HandoffKind.systemPrompt), isNull);
  });

  test('the next launch replaces the row and its consumption', () {
    dao.put(handoff('s1'));
    dao.consume('s1', at: t0);
    dao.put(handoff('s1', text: 'again', route: HandoffRoute.file));
    final read = dao.get('s1', HandoffKind.opening)!;
    expect(read.text, 'again');
    expect(read.route, HandoffRoute.file);
    expect(read.consumedAt, isNull);
  });

  test('consume marks every kind of the session, once', () {
    dao.put(handoff('s1'));
    dao.put(handoff('s1', kind: HandoffKind.systemPrompt));
    dao.put(handoff('s2'));
    expect(dao.consume('s1', at: t0), 2);
    expect(dao.consume('s1', at: t0.add(const Duration(hours: 1))), 0);
    expect(dao.get('s1', HandoffKind.opening)!.consumedAt, t0);
    expect(dao.get('s2', HandoffKind.opening)!.consumedAt, isNull);
  });

  test('consume can name one kind', () {
    dao.put(handoff('s1'));
    dao.put(handoff('s1', kind: HandoffKind.systemPrompt));
    expect(dao.consume('s1', at: t0, kind: HandoffKind.systemPrompt), 1);
    expect(dao.get('s1', HandoffKind.opening)!.consumedAt, isNull);
  });

  test('pending lists unconsumed rows, by route when asked', () {
    dao.put(handoff('s1'));
    dao.put(handoff('s2', route: HandoffRoute.file));
    expect(dao.pending().map((h) => h.sessionId), unorderedEquals(['s1', 's2']));
    expect(dao.pending(route: HandoffRoute.typed).map((h) => h.sessionId), [
      's1',
    ]);
    dao.consume('s1', at: t0);
    expect(dao.pending().map((h) => h.sessionId), ['s2']);
  });

  test('sweep deletes rows consumed before the cutoff', () {
    dao.put(handoff('s1'));
    dao.put(handoff('s2'));
    dao.consume('s1', at: t0);
    dao.consume('s2', at: t0.add(const Duration(hours: 2)));
    final removed = dao.sweep(
      before: t0.add(const Duration(hours: 1)),
      live: const {},
    );
    expect(removed, 1);
    expect(dao.get('s1', HandoffKind.opening), isNull);
    expect(dao.get('s2', HandoffKind.opening), isNotNull);
  });

  test('sweep deletes an old unconsumed row only when its session is gone', () {
    dao.put(handoff('s1', at: t0));
    dao.put(handoff('s2', at: t0));
    final removed = dao.sweep(
      before: t0.add(const Duration(days: 1)),
      live: const {'s2'},
    );
    expect(removed, 1);
    expect(dao.get('s1', HandoffKind.opening), isNull);
    expect(dao.get('s2', HandoffKind.opening), isNotNull);
  });

  test('a deleted session takes its rows with it', () {
    dao.put(handoff('s1'));
    SessionDao(db).delete('s1');
    expect(dao.get('s1', HandoffKind.opening), isNull);
  });
}
