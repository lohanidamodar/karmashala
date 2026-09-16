import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// Schema v50: the usage history table. Kept to one migration so it can be
/// renumbered at a merge without touching anything else.
void main() {
  test('v50 creates usage_samples with its recorded_at index', () {
    final db = AppDatabase.memory();
    addTearDown(db.close);

    final columns = {
      for (final row in db.query('PRAGMA table_info(usage_samples);'))
        row['name']! as String: row['notnull']! as int,
    };
    expect(columns, {
      'account_key': 1,
      'window_label': 1,
      'span_seconds': 0,
      'percent': 1,
      'resets_at': 0,
      'recorded_at': 1,
    });
    final indexes = db
        .query('PRAGMA index_list(usage_samples);')
        .map((row) => row['name'])
        .toSet();
    expect(indexes, contains('idx_usage_samples_recorded'));
  });

  test('one row per account, window and moment', () {
    final db = AppDatabase.memory();
    addTearDown(db.close);

    const insert =
        'INSERT OR REPLACE INTO usage_samples '
        '(account_key, window_label, percent, recorded_at) VALUES (?, ?, ?, ?);';
    db.execute(insert, [
      'claude@local',
      '5-hour',
      10.0,
      '2026-09-16T10:00:00.000Z',
    ]);
    db.execute(insert, [
      'claude@local',
      '5-hour',
      12.0,
      '2026-09-16T10:00:00.000Z',
    ]);
    db.execute(insert, [
      'claude@local',
      '7-day',
      3.0,
      '2026-09-16T10:00:00.000Z',
    ]);

    final rows = db.query(
      'SELECT window_label, percent FROM usage_samples ORDER BY window_label;',
    );
    expect(rows, [
      {'window_label': '5-hour', 'percent': 12.0},
      {'window_label': '7-day', 'percent': 3.0},
    ]);
  });
}
