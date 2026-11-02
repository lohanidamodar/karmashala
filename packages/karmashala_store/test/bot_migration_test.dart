import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// v95: a session can be the server's bot, which is at most one unarchived
/// row, and what it asked a person to approve is kept across a restart.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  test('the head is 95', () => expect(db.schemaVersion, 95));

  test('v95 adds a nullable role to sessions', () {
    final role = db
        .query('PRAGMA table_info(sessions);')
        .firstWhere((row) => row['name'] == 'role');
    expect(role['notnull'], 0);
  });

  test('only one unarchived row may hold a role', () {
    final index = db
        .query('PRAGMA index_list(sessions);')
        .where((row) => row['name'] == 'idx_sessions_one_bot');
    expect(index.single['unique'], 1);
    final sql =
        db
                .query(
                  'SELECT sql FROM sqlite_master '
                  "WHERE name = 'idx_sessions_one_bot';",
                )
                .single['sql']!
            as String;
    expect(sql, contains('archived_at IS NULL'));
    expect(sql, contains('role IS NOT NULL'));
  });

  test('v95 adds bot_approvals, gone with its session', () {
    final columns = {
      for (final row in db.query('PRAGMA table_info(bot_approvals);'))
        row['name']! as String,
    };
    expect(
      columns,
      containsAll(const [
        'id',
        'session_id',
        'tool',
        'arguments',
        'summary',
        'state',
        'requested_at',
        'expires_at',
        'decided_at',
        'decided_by',
        'outcome',
      ]),
    );
    final key = db.query('PRAGMA foreign_key_list(bot_approvals);').single;
    expect(key['table'], 'sessions');
    expect(key['on_delete'], 'CASCADE');
  });
}
