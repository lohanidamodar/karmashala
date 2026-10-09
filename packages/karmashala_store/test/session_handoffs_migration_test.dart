import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// v74: `session_handoffs`, the texts a session is started with, held here
/// rather than on disk and gone with their session.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  test('the head is 91', () => expect(db.schemaVersion, 91));

  test('v74 creates session_handoffs', () {
    final columns = db
        .query('PRAGMA table_info(session_handoffs);')
        .map((r) => r['name']! as String)
        .toList();
    expect(columns, [
      'session_id',
      'kind',
      'text',
      'route',
      'created_at',
      'consumed_at',
    ]);
  });

  test('deleting the session takes its handoffs with it', () {
    db.execute('PRAGMA foreign_keys = OFF;');
    db.execute(
      'INSERT INTO sessions (id, repository_id, agent_installation_id, title, '
      "use_worktree, status, created_at) VALUES ('s1', 'r1', 'a1', 'T', 0, "
      "'running', 't');",
    );
    db.execute(
      'INSERT INTO session_handoffs (session_id, kind, text, route, '
      "created_at) VALUES ('s1', 'opening', 'hi', 'typed', 't');",
    );
    db.execute('PRAGMA foreign_keys = ON;');
    db.execute("DELETE FROM sessions WHERE id = 's1';");
    expect(db.query('SELECT COUNT(*) AS n FROM session_handoffs;').first, {
      'n': 0,
    });
  });
}
