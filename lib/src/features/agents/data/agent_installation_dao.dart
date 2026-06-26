import '../../../core/database/app_database.dart';
import '../../../core/database/row_mapping.dart';
import '../../environments/domain/environment_path.dart';
import '../domain/agent_installation.dart';
import '../domain/agent_kind.dart';

/// Data-access for [AgentInstallation] rows. Hand-written SQL, no codegen.
///
/// The underlying table has a `UNIQUE(agent_kind, environment_id,
/// executable_path)` constraint, enforcing that each `(agent, environment,
/// executable)` is one independent installation.
class AgentInstallationDao {
  AgentInstallationDao(this._db);

  final AppDatabase _db;

  void insert(AgentInstallation installation) {
    _db.execute(
      'INSERT INTO agent_installations '
      '(id, agent_kind, environment_id, executable_path, version, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?);',
      [
        installation.id,
        installation.agentKind.name,
        installation.executable.environmentId,
        installation.executable.path,
        installation.version,
        isoFromDate(installation.createdAt),
      ],
    );
  }

  AgentInstallation? getById(String id) {
    final rows = _db.query('SELECT * FROM agent_installations WHERE id = ?;', [
      id,
    ]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// Finds an installation by its natural identity — `(agentKind, environmentId,
  /// executablePath)` — which the table enforces as unique.
  AgentInstallation? getByIdentity(
    AgentKind agentKind,
    String environmentId,
    String executablePath,
  ) {
    final rows = _db.query(
      'SELECT * FROM agent_installations WHERE agent_kind = ? '
      'AND environment_id = ? AND executable_path = ?;',
      [agentKind.name, environmentId, executablePath],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  List<AgentInstallation> getAll() {
    final rows = _db.query(
      'SELECT * FROM agent_installations ORDER BY created_at, id;',
    );
    return rows.map(_fromRow).toList();
  }

  /// Installations available in a given environment.
  List<AgentInstallation> getByEnvironment(String environmentId) {
    final rows = _db.query(
      'SELECT * FROM agent_installations WHERE environment_id = ? '
      'ORDER BY created_at, id;',
      [environmentId],
    );
    return rows.map(_fromRow).toList();
  }

  void delete(String id) {
    _db.execute('DELETE FROM agent_installations WHERE id = ?;', [id]);
  }

  AgentInstallation _fromRow(Map<String, Object?> row) => AgentInstallation(
    id: row['id']! as String,
    agentKind: AgentKind.values.byName(row['agent_kind']! as String),
    executable: EnvironmentPath(
      environmentId: row['environment_id']! as String,
      path: row['executable_path']! as String,
    ),
    version: row['version'] as String?,
    createdAt: dateFromIso(row['created_at']),
  );
}
