import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/migrations.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// Schema v81: webhook automations and their call log. (v80 is another
/// round's; until it lands this branch holds a gap there.)
void main() {
  Set<String> columnsOf(Database db, String table) => {
    for (final row in db.select('PRAGMA table_info($table);'))
      row['name']! as String,
  };

  Database upTo(int version) {
    final raw = sqlite3.openInMemory();
    for (final step in schemaMigrations.keys.toList()..sort()) {
      if (step > version) break;
      schemaMigrations[step]!(raw);
    }
    return raw;
  }

  test('the head is 91', () {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    expect(db.schemaVersion, 91);
  });

  test('v81 adds the webhook columns and a call log with no body', () {
    final before = upTo(80);
    addTearDown(before.close);
    expect(columnsOf(before, 'automations'), isNot(contains('webhook_id')));
    final raw = upTo(81);
    addTearDown(raw.close);
    expect(
      columnsOf(raw, 'automations'),
      containsAll([
        'webhook_id',
        'webhook_signature',
        'webhook_model',
        'webhook_worktree',
        'webhook_per_hour',
      ]),
    );
    final log = columnsOf(raw, 'webhook_calls');
    expect(log, containsAll(['hook_id', 'received_at', 'ip', 'body_sha256']));
    expect(log, isNot(contains('body')));
    expect(log.where((c) => c.contains('secret')), isEmpty);
  });
}
