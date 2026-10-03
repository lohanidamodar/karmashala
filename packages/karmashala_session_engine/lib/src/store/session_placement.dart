import 'package:agent_cli/process.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';

import '../domain/session_placement_rule.dart';
import '../service/hosted_session_status_keeper.dart';
import '../service/session_lifecycle_recorder.dart';
import 'session_dao.dart';

/// The daemon's [HostedSessionStatusKeeper] over the store. [resolveUnknown]
/// says what a host's silence means for the rows the server's own runtimes
/// hold (an agent spoken to over a protocol) — an end, never `unknown`.
HostedSessionStatusKeeper keeperOver(
  AppDatabase db, {
  UnknownResolver? resolveUnknown,
}) => HostedSessionStatusKeeper(
  SessionDao(db),
  runsOnThisMachine: (session) => sessionRunsOnThisMachine(db, session),
  resolveUnknown: resolveUnknown,
);

/// [runsOnThisMachine] over the store's own tables.
bool sessionRunsOnThisMachine(AppDatabase db, Session session) =>
    runsOnThisMachine(
      session,
      environmentOfRepository: (repositoryId) => _firstValue(
        db,
        'SELECT environment_id FROM repositories WHERE id = ?;',
        [repositoryId],
      ),
      kindOf: (environmentId) =>
          EnvironmentKind.values.asNameMap()[_firstValue(
            db,
            'SELECT kind FROM execution_environments WHERE id = ?;',
            [environmentId],
          )],
    );

String? _firstValue(AppDatabase db, String sql, List<Object?> params) {
  final rows = db.query(sql, params);
  return rows.isEmpty ? null : rows.first.values.first as String?;
}
