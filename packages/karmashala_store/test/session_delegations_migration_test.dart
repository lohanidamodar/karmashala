import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// v73: `session_delegations`, the async children whose turn results are
/// pushed to their parent, gone with either session.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  test('the head is 90', () => expect(db.schemaVersion, 90));

  test('v73 creates session_delegations', () {
    final columns = db
        .query('PRAGMA table_info(session_delegations);')
        .map((r) => r['name']! as String)
        .toList();
    expect(columns.take(9), [
      'child_session_id',
      'parent_session_id',
      'title',
      'agent',
      'model',
      'end_on_answer',
      'delegated_at',
      'turn',
      'turn_started_at',
    ]);
  });

  for (final gone in ['parent', 'child']) {
    test('deleting the $gone session takes its delegation with it', () {
      db.execute('PRAGMA foreign_keys = OFF;');
      for (final id in ['parent', 'child']) {
        db.execute(
          'INSERT INTO sessions (id, repository_id, agent_installation_id, '
          "title, use_worktree, status, created_at) VALUES (?, 'r1', 'a1', "
          "'T', 0, 'running', 't');",
          [id],
        );
      }
      db.execute(
        'INSERT INTO session_delegations (child_session_id, '
        'parent_session_id, title, agent, end_on_answer, delegated_at, turn, '
        "turn_started_at) VALUES ('child', 'parent', 'T', 'A', 0, 't', 1, "
        "'t');",
      );
      db.execute('PRAGMA foreign_keys = ON;');
      db.execute('DELETE FROM sessions WHERE id = ?;', [gone]);
      expect(db.query('SELECT COUNT(*) AS n FROM session_delegations;').first, {
        'n': 0,
      });
    });
  }
}
