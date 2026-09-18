import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/migrations.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// Schema v54: a context's colour. Kept to one migration so it can be
/// renumbered at a merge without touching anything else.
void main() {
  test('v54 adds a nullable color column to workspaces', () {
    final db = AppDatabase.memory();
    addTearDown(db.close);

    final columns = {
      for (final row in db.query('PRAGMA table_info(workspaces);'))
        row['name']! as String: row['notnull']! as int,
    };
    expect(columns, containsPair('color', 0));
    expect(db.schemaVersion, 54);

    db.execute(
      "INSERT INTO workspaces (id, name, created_at) VALUES ('w', 'Work', 't');",
    );
    expect(
      db.query("SELECT color FROM workspaces WHERE id = 'w';").single['color'],
      isNull,
      reason: 'a context has no colour until one is picked',
    );
  });

  test('the step is idempotent, as a re-numbered merge needs it to be', () {
    final raw = sqlite3.openInMemory();
    addTearDown(raw.close);
    for (final version in schemaMigrations.keys.toList()..sort()) {
      schemaMigrations[version]!(raw);
    }
    schemaMigrations[54]!(raw);
    final colour = raw
        .select('PRAGMA table_info(workspaces);')
        .where((row) => row['name'] == 'color');
    expect(colour, hasLength(1));
  });
}
