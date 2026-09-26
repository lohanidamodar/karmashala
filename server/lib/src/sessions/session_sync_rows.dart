import 'package:agent_cli/discovery.dart' show AgentInstallation;
import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/store.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';

import '../data/data_service.dart';

/// What the session sync reads of the server's store, and the one way it
/// writes: through the data service, as a request of the server's own — so
/// every rule a client's write follows applies to it, and every client is
/// told the row (and the conversation index reads the conversation it names).
class SessionSyncRows {
  SessionSyncRows(
    AppDatabase database,
    DataService data, {
    void Function(String message)? log,
  }) : sessions = SessionDao(database),
       _repositories = RepositoryDao(database),
       _installations = AgentInstallationDao(database),
       _environments = ExecutionEnvironmentDao(database),
       _link = data.open(_nobody),
       _log = log;

  static void _nobody(DataChanges _) {}

  final SessionDao sessions;
  final RepositoryDao _repositories;
  final AgentInstallationDao _installations;
  final ExecutionEnvironmentDao _environments;

  /// The server's own link: never subscribed, so it is told nothing back,
  /// and every other client is told what it writes.
  final DataSession _link;
  final void Function(String message)? _log;

  /// Rows this sync wrote, over its life: the cost claims' numerator.
  int writes = 0;

  List<Repository> repositories() => _repositories.getAll();

  Repository? repository(String id) => _repositories.getById(id);

  AgentInstallation? installation(String id) => _installations.getById(id);

  List<AgentInstallation> installationsIn(String environmentId) =>
      _installations.getByEnvironment(environmentId);

  Map<String, ExecutionEnvironment> environments() => {
    for (final environment in _environments.getAll())
      environment.id: environment,
  };

  /// The agent a row runs, by its installation, or null.
  String? agentOf(Session row) =>
      installation(row.agentInstallationId)?.agentId;

  /// Where a row's agent works, in decreasing certainty: where the process
  /// started, its worktree, its checkout.
  EnvironmentPath? directoryOf(Session row) {
    final directory =
        row.workingDirectory ??
        row.worktree ??
        repository(row.repositoryId)?.path;
    if (directory == null || directory.path.isEmpty) return null;
    return directory;
  }

  /// Writes [patch] on [id] and answers the row as stored, or null when the
  /// data service refused it (the reason is logged).
  Session? edit(String id, SessionPatch patch) {
    try {
      final stored = _link.handle(SessionEdit(id, patch)).value;
      writes++;
      return stored;
    } on DataRefused catch (refusal) {
      _log?.call('session sync: ${SessionEdit.name} $id refused ($refusal)');
      return null;
    }
  }

  /// Records [session] with its checkout as the primary one, or null when
  /// refused.
  Session? create(Session session) {
    try {
      final stored = _link.handle(SessionCreate(session)).value;
      writes++;
      return stored;
    } on DataRefused catch (refusal) {
      _log?.call(
        'session sync: ${SessionCreate.name} ${session.id} refused ($refusal)',
      );
      return null;
    }
  }

  void close() => _link.close();
}
