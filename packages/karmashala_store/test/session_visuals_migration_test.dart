import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// v90: `session_visuals`, what agents drew with `visualize`, one row per
/// visual by the id it is updated by.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  test('the head is 92', () => expect(db.schemaVersion, 92));

  test('v90 creates session_visuals, keyed by session and id', () {
    final columns = db
        .query('PRAGMA table_info(session_visuals);')
        .map((r) => r['name']! as String)
        .toList();
    expect(columns, [
      'session_id',
      'id',
      'kind',
      'title',
      'spec',
      'revision',
      'created_at',
      'updated_at',
    ]);
    const insert =
        'INSERT INTO session_visuals (session_id, id, kind, spec, revision, '
        'created_at, updated_at) VALUES (?, ?, ?, ?, 1, ?, ?);';
    db.execute(insert, ['s1', 'v', 'chart', '{}', 't', 't']);
    db.execute(insert, ['s2', 'v', 'chart', '{}', 't', 't']);
    expect(
      () => db.execute(insert, ['s1', 'v', 'chart', '{}', 't', 't']),
      throwsA(anything),
    );
  });
}
