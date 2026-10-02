import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// v69: `session_usage`, what an ACP session's agent reported of its own
/// context and cost — one row per session, a turn series inside it.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  test('v69 creates session_usage keyed by session', () {
    final columns = db
        .query('PRAGMA table_info(session_usage);')
        .map((r) => r['name']! as String)
        .toList();
    expect(columns, [
      'session_id',
      'context_used',
      'context_size',
      'cost_amount',
      'cost_currency',
      'turns_json',
      'updated_at',
    ]);
  });

  test('every usage column is null until the agent said it', () {
    db.execute('PRAGMA foreign_keys = OFF;');
    db.execute(
      "INSERT INTO session_usage (session_id, updated_at) VALUES ('s1', 't');",
    );
    final row = db.query('SELECT * FROM session_usage;').single;
    expect(row['context_used'], isNull);
    expect(row['context_size'], isNull);
    expect(row['cost_amount'], isNull);
    expect(row['cost_currency'], isNull);
    expect(row['turns_json'], '[]');
  });

  test('deleting the session takes its usage with it', () {
    db.execute('PRAGMA foreign_keys = OFF;');
    db.execute(
      'INSERT INTO sessions (id, repository_id, agent_installation_id, title, '
      "use_worktree, status, created_at) VALUES ('s1', 'r1', 'a1', 'T', 0, "
      "'running', 't');",
    );
    db.execute(
      "INSERT INTO session_usage (session_id, updated_at) VALUES ('s1', 't');",
    );
    db.execute('PRAGMA foreign_keys = ON;');
    db.execute("DELETE FROM sessions WHERE id = 's1';");
    expect(db.query('SELECT COUNT(*) AS n FROM session_usage;').first, {
      'n': 0,
    });
  });
}
