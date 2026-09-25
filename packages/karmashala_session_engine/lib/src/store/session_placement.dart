import 'package:agent_cli/process.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';

/// Whether [session] runs on this machine — Windows, WSL or the local POSIX
/// host — and so under this machine's session host. False for SSH, and for a
/// row whose environment cannot be found: no local fact can speak for it.
bool sessionRunsOnThisMachine(AppDatabase db, Session session) {
  final environmentId =
      session.workingDirectory?.environmentId ??
      _firstValue(db, 'SELECT environment_id FROM repositories WHERE id = ?;', [
        session.repositoryId,
      ]);
  if (environmentId == null) return false;
  final kindName = _firstValue(
    db,
    'SELECT kind FROM execution_environments WHERE id = ?;',
    [environmentId],
  );
  final kind = EnvironmentKind.values.asNameMap()[kindName];
  return kind != null && kind != EnvironmentKind.ssh;
}

String? _firstValue(AppDatabase db, String sql, List<Object?> params) {
  final rows = db.query(sql, params);
  return rows.isEmpty ? null : rows.first.values.first as String?;
}
