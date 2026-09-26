import 'package:karmashala_store/database.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_ssh/connection.dart';

/// Data-access for saved [SshHost] rows. Nothing here writes a secret: the
/// table has no password or key column, only the *location* of a key file.
class SshHostDao implements SshHostStore {
  SshHostDao(this._db);

  final AppDatabase _db;

  void upsert(SshHost host) {
    _db.execute(
      'INSERT INTO ssh_hosts '
      '(id, name, host, port, username, auth_method, private_key_path, '
      'private_key_environment_id, default_directory, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET '
      'name = excluded.name, host = excluded.host, port = excluded.port, '
      'username = excluded.username, auth_method = excluded.auth_method, '
      'private_key_path = excluded.private_key_path, '
      'private_key_environment_id = excluded.private_key_environment_id, '
      'default_directory = excluded.default_directory;',
      [
        host.id,
        host.name,
        host.host,
        host.port,
        host.username,
        host.authMethod.name,
        host.privateKey?.path,
        host.privateKey?.environmentId,
        host.defaultDirectory?.path,
        isoFromDate(host.createdAt),
      ],
    );
  }

  @override
  SshHost? getById(String id) {
    final rows = _db.query('SELECT * FROM ssh_hosts WHERE id = ?;', [id]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  List<SshHost> getAll() {
    final rows = _db.query('SELECT * FROM ssh_hosts ORDER BY created_at, id;');
    return rows.map(_fromRow).toList();
  }

  void delete(String id) {
    _db.execute('DELETE FROM ssh_hosts WHERE id = ?;', [id]);
  }

  SshHost _fromRow(Map<String, Object?> row) {
    final id = row['id']! as String;
    final keyPath = row['private_key_path'] as String?;
    final keyEnv = row['private_key_environment_id'] as String?;
    final defaultDir = row['default_directory'] as String?;
    return SshHost(
      id: id,
      name: row['name']! as String,
      host: row['host']! as String,
      port: row['port']! as int,
      username: row['username']! as String,
      authMethod: SshAuthMethod.values.byName(row['auth_method']! as String),
      // A key path without its environment is not a path we are willing to use
      // (principle 2), so both columns must be present or neither is read.
      privateKey: keyPath == null || keyEnv == null
          ? null
          : EnvironmentPath(environmentId: keyEnv, path: keyPath),
      defaultDirectory: defaultDir == null
          ? null
          : EnvironmentPath(
              environmentId: sshEnvironmentId(id),
              path: defaultDir,
            ),
      createdAt: dateFromIso(row['created_at']),
    );
  }
}
