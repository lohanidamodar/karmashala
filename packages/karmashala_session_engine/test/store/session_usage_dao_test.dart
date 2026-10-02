import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import '../support/store_fixtures.dart';

/// `session_usage`: the agent's latest report replaces the last, a turn's end
/// appends to the series, and nothing the agent never said reads as zero.
void main() {
  late AppDatabase db;
  late SessionUsageDao dao;
  final t0 = DateTime.utc(2026, 10, 2, 12);

  setUp(() {
    db = AppDatabase.memory();
    seedWorkspace(db);
    SessionDao(db).insert(session());
    dao = SessionUsageDao(db);
  });
  tearDown(() => db.close());

  test('a session with no report has no row', () {
    expect(dao.getBySession('s1'), isNull);
  });

  test('the latest report replaces the last and keeps the turns', () {
    dao.recordTurn(
      's1',
      const SessionUsageTurn(contextUsed: 1000, contextSize: 200000),
      at: t0,
    );
    final latest = dao.recordLatest(
      's1',
      contextUsed: 1500,
      contextSize: 200000,
      at: t0.add(const Duration(seconds: 5)),
    );
    expect(latest.contextUsed, 1500);
    expect(latest.turns.map((t) => t.contextUsed), [1000]);
    final read = dao.getBySession('s1')!;
    expect(read.contextUsed, 1500);
    expect(read.contextSize, 200000);
    expect(read.costAmount, isNull);
    expect(read.turns.length, 1);
    expect(read.updatedAt, t0.add(const Duration(seconds: 5)));
  });

  test('a turn appends to the series and its cost carries forward', () {
    dao.recordTurn(
      's1',
      const SessionUsageTurn(
        contextUsed: 1000,
        contextSize: 200000,
        costAmount: 0.25,
        costCurrency: 'USD',
      ),
      at: t0,
    );
    dao.recordTurn(
      's1',
      const SessionUsageTurn(contextUsed: 2400, contextSize: 200000),
      at: t0,
    );
    final read = dao.getBySession('s1')!;
    expect(read.turns.map((t) => t.contextUsed), [1000, 2400]);
    expect(read.turns.first.costAmount, 0.25);
    expect(read.turns.last.costAmount, isNull);
    // The latest cost is the last one the agent gave, not forgotten.
    expect(read.costAmount, 0.25);
    expect(read.costCurrency, 'USD');
    expect(read.contextUsed, 2400);
  });

  test('a malformed turn series reads as no turns, not as an error', () {
    db.execute(
      'INSERT INTO session_usage (session_id, turns_json, updated_at) '
      "VALUES ('s1', 'not json', '2026-10-02T12:00:00.000Z');",
    );
    expect(dao.getBySession('s1')!.turns, isEmpty);
  });

  test('deleting the usage leaves no row', () {
    dao.recordLatest('s1', contextUsed: 1, contextSize: 2, at: t0);
    dao.deleteForSession('s1');
    expect(dao.getBySession('s1'), isNull);
  });
}
