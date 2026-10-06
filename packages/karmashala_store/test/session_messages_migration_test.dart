import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/migrations.dart';
import 'package:test/test.dart';

/// v65: `session_messages`, the rows an ACP session's conversation is kept in.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  test('the head is 80 and the keys stay contiguous', () {
    expect(schemaMigrations.keys.toList()..sort(), [
      for (var v = 1; v <= schemaMigrations.length; v++) v,
    ]);
    expect(db.schemaVersion, 80);
  });

  test('v65 creates session_messages with its revision index', () {
    final columns = db
        .query('PRAGMA table_info(session_messages);')
        .map((r) => r['name']! as String)
        .toList();
    expect(columns, [
      'id',
      'session_id',
      'ordinal',
      'role',
      'text',
      'thinking',
      'tool_json',
      'plan_json',
      'message_id',
      'revision',
      'created_at',
      'updated_at',
    ]);
    final indexes = db
        .query("PRAGMA index_list('session_messages');")
        .map((r) => r['name'])
        .toList();
    expect(indexes, contains('idx_session_messages_revision'));
  });

  test('one ordinal per session, and text defaults to empty', () {
    db.execute('PRAGMA foreign_keys = OFF;');
    db.execute(
      'INSERT INTO session_messages (id, session_id, ordinal, role, revision, '
      "created_at, updated_at) VALUES ('m1', 's1', 0, 'user', 1, 't', 't');",
    );
    expect(
      () => db.execute(
        'INSERT INTO session_messages (id, session_id, ordinal, role, '
        "revision, created_at, updated_at) "
        "VALUES ('m2', 's1', 0, 'agent', 2, 't', 't');",
      ),
      throwsA(anything),
    );
    expect(
      db.query("SELECT text FROM session_messages WHERE id = 'm1';").first,
      {'text': ''},
    );
  });

  test('deleting the session cascades to its messages', () {
    // Parents are skipped so the one cascade under test stands alone.
    db.execute('PRAGMA foreign_keys = OFF;');
    db.execute(
      'INSERT INTO sessions (id, repository_id, agent_installation_id, title, '
      "use_worktree, status, created_at) VALUES ('s1', 'r1', 'a1', 'T', 0, "
      "'running', 't');",
    );
    db.execute(
      'INSERT INTO session_messages (id, session_id, ordinal, role, revision, '
      "created_at, updated_at) VALUES ('m1', 's1', 0, 'user', 1, 't', 't');",
    );
    db.execute('PRAGMA foreign_keys = ON;');
    db.execute("DELETE FROM sessions WHERE id = 's1';");
    expect(db.query('SELECT COUNT(*) AS n FROM session_messages;').first, {
      'n': 0,
    });
  });
}
