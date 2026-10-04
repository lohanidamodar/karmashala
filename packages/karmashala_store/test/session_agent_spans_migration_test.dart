import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// v72: `session_agent_spans`, each agent a session ran under, gone with
/// their session.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  test('the head is 73', () => expect(db.schemaVersion, 73));

  test('v72 creates session_agent_spans', () {
    final columns = db
        .query('PRAGMA table_info(session_agent_spans);')
        .map((r) => r['name']! as String)
        .toList();
    expect(columns, [
      'session_id',
      'seq',
      'agent_installation_id',
      'external_session_id',
      'started_at',
      'first_message_ordinal',
      'carried_packet',
    ]);
  });

  test('deleting the session takes its spans with it', () {
    db.execute('PRAGMA foreign_keys = OFF;');
    db.execute(
      'INSERT INTO sessions (id, repository_id, agent_installation_id, title, '
      "use_worktree, status, created_at) VALUES ('s1', 'r1', 'a1', 'T', 0, "
      "'running', 't');",
    );
    db.execute(
      'INSERT INTO session_agent_spans (session_id, seq, '
      "agent_installation_id, started_at) VALUES ('s1', 0, 'a1', 't');",
    );
    db.execute('PRAGMA foreign_keys = ON;');
    db.execute("DELETE FROM sessions WHERE id = 's1';");
    expect(
      db.query('SELECT COUNT(*) AS n FROM session_agent_spans;').first,
      {'n': 0},
    );
  });
}
