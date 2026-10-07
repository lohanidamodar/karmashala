import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// v71: `session_queued_messages`, messages kept at the server while a turn
/// runs, gone with their session; v75: who cancelled one.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  test('the head is 89', () => expect(db.schemaVersion, 89));

  test('v71 creates session_queued_messages, and v75 adds cancelled_by', () {
    final columns = db
        .query('PRAGMA table_info(session_queued_messages);')
        .map((r) => r['name']! as String)
        .toList();
    expect(columns, [
      'id',
      'session_id',
      'seq',
      'text',
      'state',
      'origin',
      'origin_id',
      'created_at',
      'updated_at',
      'delivered_at',
      'request_id',
      'error',
      'cancelled_by',
    ]);
  });

  test('deleting the session takes its queued messages with it', () {
    db.execute('PRAGMA foreign_keys = OFF;');
    db.execute(
      'INSERT INTO sessions (id, repository_id, agent_installation_id, title, '
      "use_worktree, status, created_at) VALUES ('s1', 'r1', 'a1', 'T', 0, "
      "'running', 't');",
    );
    db.execute(
      'INSERT INTO session_queued_messages (id, session_id, seq, text, state, '
      "origin, created_at, updated_at) VALUES ('q1', 's1', 1, 'hi', 'queued', "
      "'app', 't', 't');",
    );
    db.execute('PRAGMA foreign_keys = ON;');
    db.execute("DELETE FROM sessions WHERE id = 's1';");
    expect(
      db.query('SELECT COUNT(*) AS n FROM session_queued_messages;').first,
      {'n': 0},
    );
  });
}
