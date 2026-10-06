import 'package:karmashala_store/migrations.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

Database _migratedTo(int upTo) {
  final db = sqlite3.openInMemory();
  final versions = schemaMigrations.keys.where((v) => v <= upTo).toList()
    ..sort();
  for (final version in versions) {
    schemaMigrations[version]!(db);
    db.execute('PRAGMA user_version = $version;');
  }
  return db;
}

/// v78: a pairing's relay can move; existing rows start settled.
void main() {
  const oldRelay = 'wss://relay.popupbits.com';
  final id = 'a' * 32;

  test('v78 leaves every existing pairing settled where it is', () {
    final db = _migratedTo(77);
    addTearDown(db.close);
    db.execute(
      'INSERT INTO paired_devices (id, name, device_key, capabilities, '
      'generation, revoked, created_at, relay_url) VALUES '
      "(?, 'OPPO', '00', 1, 3, 0, '2026-10-06T00:00:00.000Z', ?);",
      [id, oldRelay],
    );

    schemaMigrations[78]!(db);

    final row = db.select('SELECT * FROM paired_devices;').single;
    expect(row['relay_url'], oldRelay);
    expect(row['relay_move_to'], isNull);
    expect(row['relay_moved_from'], isNull);
    expect(row['relay_move_settled'], 1);
  });
}
