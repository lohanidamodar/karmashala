import 'package:karmashala_store/database.dart';
import 'package:agent_cli/process.dart';

/// Data-access for [ExecutionEnvironment] rows. Hand-written SQL, no codegen.
class ExecutionEnvironmentDao {
  ExecutionEnvironmentDao(this._db);

  final AppDatabase _db;

  /// Inserts a new environment, or replaces an existing one with the same id.
  void upsert(ExecutionEnvironment env) {
    _db.execute(
      'INSERT INTO execution_environments '
      '(id, kind, name, wsl_distribution, ssh_host_id, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET '
      'kind = excluded.kind, name = excluded.name, '
      'wsl_distribution = excluded.wsl_distribution, '
      'ssh_host_id = excluded.ssh_host_id;',
      [
        env.id,
        env.kind.name,
        env.name,
        env.wslDistribution,
        env.sshHostId,
        isoFromDate(env.createdAt),
      ],
    );
  }

  ExecutionEnvironment? getById(String id) {
    final rows = _db.query(
      'SELECT * FROM execution_environments WHERE id = ?;',
      [id],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  List<ExecutionEnvironment> getAll() {
    final rows = _db.query(
      'SELECT * FROM execution_environments ORDER BY created_at, id;',
    );
    return rows.map(_fromRow).toList();
  }

  void delete(String id) {
    _db.execute('DELETE FROM execution_environments WHERE id = ?;', [id]);
  }

  ExecutionEnvironment _fromRow(Map<String, Object?> row) =>
      ExecutionEnvironment(
        id: row['id']! as String,
        kind: EnvironmentKind.values.byName(row['kind']! as String),
        name: row['name']! as String,
        wslDistribution: row['wsl_distribution'] as String?,
        sshHostId: row['ssh_host_id'] as String?,
        createdAt: dateFromIso(row['created_at']),
      );
}
