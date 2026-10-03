import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// v70: `acp_auth_choices`, the auth method a person chose for an ACP
/// installation, gone with the installation.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  test('v70 creates acp_auth_choices keyed by installation', () {
    final columns = db
        .query('PRAGMA table_info(acp_auth_choices);')
        .map((r) => r['name']! as String)
        .toList();
    expect(columns, [
      'installation_id',
      'method_id',
      'method_name',
      'authenticated_at',
      'chosen_at',
    ]);
  });

  test('deleting the installation takes its choice with it', () {
    db.execute('PRAGMA foreign_keys = OFF;');
    db.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      "executable_path, created_at) VALUES ('a1', 'x', 'e1', 'p', 't');",
    );
    db.execute(
      'INSERT INTO acp_auth_choices (installation_id, method_id, method_name, '
      "chosen_at) VALUES ('a1', 'm', 'M', 't');",
    );
    db.execute('PRAGMA foreign_keys = ON;');
    db.execute("DELETE FROM agent_installations WHERE id = 'a1';");
    expect(db.query('SELECT COUNT(*) AS n FROM acp_auth_choices;').first, {
      'n': 0,
    });
  });
}
