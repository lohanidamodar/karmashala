import 'package:karmashala_store/database.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// Schema v53: scheduled resumes. Kept to one migration so it can be
/// renumbered at a merge without touching anything else.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  void insert(String id, String sessionId, String state) => db.execute(
    'INSERT INTO scheduled_resumes (id, session_id, fire_at, state, '
    "scheduled_at) VALUES (?, ?, '2026-09-17T14:05:00.000Z', ?, "
    "'2026-09-17T12:00:00.000Z');",
    [id, sessionId, state],
  );

  test('v53 creates scheduled_resumes with its two indexes', () {
    final columns = {
      for (final row in db.query('PRAGMA table_info(scheduled_resumes);'))
        row['name']! as String: row['notnull']! as int,
    };
    expect(columns, {
      'id': 0,
      'session_id': 1,
      'account_key': 1,
      'account_email': 0,
      'window_label': 0,
      'resets_at': 0,
      'fire_at': 1,
      'message': 1,
      'permission_mode': 0,
      'notify': 1,
      'late_policy': 1,
      'state': 1,
      'reason': 1,
      'attempts': 1,
      'live_when_scheduled': 1,
      'scheduled_by': 1,
      'scheduled_at': 1,
      'finished_at': 0,
    });
    final indexes = db
        .query('PRAGMA index_list(scheduled_resumes);')
        .map((row) => row['name'])
        .toSet();
    expect(
      indexes,
      containsAll([
        'idx_scheduled_resumes_live',
        'idx_scheduled_resumes_fire_at',
      ]),
    );
  });

  test('a session holds one live row, and any number of ended ones', () {
    db.execute('PRAGMA foreign_keys = OFF;');
    insert('a', 's1', 'done');
    insert('b', 's1', 'cancelled');
    insert('c', 's1', 'pending');
    expect(() => insert('d', 's1', 'queued'), throwsA(isA<SqliteException>()));
    insert('e', 's2', 'pending');
  });

  test('the row goes with its session', () {
    expect(
      () => insert('a', 'no-such-session', 'pending'),
      throwsA(isA<SqliteException>()),
    );
  });
}
