import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// v94: a saved SSH host can be a container Karmashala created — the host it
/// is reached through, where its Docker runs, and what it was made with.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  test('the head is 94', () => expect(db.schemaVersion, 94));

  test('v94 adds nullable container columns to ssh_hosts', () {
    final columns = {
      for (final row in db.query('PRAGMA table_info(ssh_hosts);'))
        row['name']! as String: row,
    };
    for (final name in const [
      'via_host_id',
      'container_environment_id',
      'container_name',
      'container_id',
      'container_details',
    ]) {
      expect(columns, contains(name));
      expect(columns[name]!['notnull'], 0, reason: name);
    }
    // A row an older server writes, naming none of them, still inserts.
    db.execute(
      'INSERT INTO ssh_hosts (id, name, host, port, username, auth_method, '
      "created_at) VALUES ('h', 'h', 'h.example', 22, 'me', 'privateKey', "
      "'2026-10-17T00:00:00Z');",
    );
    expect(
      db.query('SELECT container_id FROM ssh_hosts;').single['container_id'],
      isNull,
    );
  });
}
