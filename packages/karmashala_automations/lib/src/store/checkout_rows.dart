import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_store/database.dart';

/// The checkout, installation and environment rows an unattended run reads,
/// for a reader without the app's DAOs (the session host). Reads only.
class CheckoutRows {
  CheckoutRows(this._db);

  final AppDatabase _db;

  Repository? repository(String id) {
    final rows = _db.query('SELECT * FROM repositories WHERE id = ?;', [id]);
    if (rows.isEmpty) return null;
    final row = rows.first;
    return Repository(
      id: row['id']! as String,
      projectId: row['project_id']! as String,
      name: row['name']! as String,
      path: EnvironmentPath(
        environmentId: row['environment_id']! as String,
        path: row['path']! as String,
      ),
      createdAt: dateFromIso(row['created_at']),
      canonicalId: row['canonical_id'] as String?,
    );
  }

  AgentInstallation? installation(String id) {
    final rows = _db.query('SELECT * FROM agent_installations WHERE id = ?;', [
      id,
    ]);
    if (rows.isEmpty) return null;
    final row = rows.first;
    return AgentInstallation(
      id: row['id']! as String,
      agentId: row['agent_kind']! as String,
      executable: EnvironmentPath(
        environmentId: row['environment_id']! as String,
        path: row['executable_path']! as String,
      ),
      version: row['version'] as String?,
      createdAt: dateFromIso(row['created_at']),
      executableByUser: boolFromInt(row['executable_by_user'] ?? 0),
    );
  }

  ExecutionEnvironment? environment(String id) {
    final rows = _db.query(
      'SELECT * FROM execution_environments WHERE id = ?;',
      [id],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return ExecutionEnvironment(
      id: row['id']! as String,
      kind: EnvironmentKind.values.byName(row['kind']! as String),
      name: row['name']! as String,
      wslDistribution: row['wsl_distribution'] as String?,
      sshHostId: row['ssh_host_id'] as String?,
      createdAt: dateFromIso(row['created_at']),
    );
  }
}
