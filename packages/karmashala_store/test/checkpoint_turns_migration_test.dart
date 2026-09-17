import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// Schema v52: a checkpoint's turn, prompt and per-file line counts. Kept to
/// one migration so it can be renumbered at a merge without touching anything
/// else.
void main() {
  test('v52 adds nullable turn, prompt and line-count columns', () {
    final db = AppDatabase.memory();
    addTearDown(db.close);

    Map<String, int> columns(String table) => {
      for (final row in db.query('PRAGMA table_info($table);'))
        row['name']! as String: row['notnull']! as int,
    };
    expect(columns('session_checkpoints'), containsPair('turn', 0));
    expect(columns('session_checkpoints'), containsPair('prompt', 0));
    expect(columns('session_checkpoint_files'), containsPair('additions', 0));
    expect(columns('session_checkpoint_files'), containsPair('deletions', 0));
    final indexes = db
        .query('PRAGMA index_list(session_checkpoints);')
        .map((row) => row['name'])
        .toSet();
    expect(indexes, contains('idx_session_checkpoints_repository'));
  });
}
