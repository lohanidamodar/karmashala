import 'package:agent_cli/descriptors.dart' show PermissionRisk;
import 'package:agent_cli/process.dart';
import 'package:karmashala_environments/store.dart' show AgentInstallationDao;
import 'package:karmashala_git/repositories.dart' show samePath;
import 'package:karmashala_projects/store.dart' show RepositoryDao;
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart'
    show SessionDao, SessionRepositoryDao;

import 'server_tool_context.dart';
import 'session_liveness.dart';

/// The live sessions that may write in [directory], as the server records
/// them: working there (their own directory, or a checkout attached to them),
/// live by [liveness], and in a mode that writes. A session that chose no mode
/// follows the app's per-agent default, which the server does not hold — so
/// it counts: an unknown mode is never assumed to be read-only.
List<CheckoutOccupant> serverCheckoutOccupants(
  ServerToolContext context,
  EnvironmentPath directory, {
  SessionLiveness liveness = SessionLiveness.rowsOnly,
  String? excluding,
}) {
  final repositories = RepositoryDao(context.database);
  final links = SessionRepositoryDao(context.database);
  final installations = AgentInstallationDao(context.database);

  Iterable<EnvironmentPath> directoriesOf(Session session) sync* {
    final own =
        session.workingDirectory ??
        session.worktree ??
        repositories.getById(session.repositoryId)?.path;
    if (own != null) yield own;
    for (final link in links.linksFor(session.id)) {
      if (link.isPrimary) continue;
      if (repositories.getById(link.repositoryId) case final repository?) {
        yield repository.path;
      }
    }
  }

  bool mayWrite(Session session) {
    final mode = session.permissionMode;
    if (mode == null || mode.isEmpty) return true;
    final installation = installations.getById(session.agentInstallationId);
    final support = installation == null
        ? null
        : context.agents.byId(installation.agentId)?.launch.permission;
    return support?.riskOf(support.resolveStored(mode)) !=
        PermissionRisk.readOnly;
  }

  return [
    for (final session in sessionsWritingIn(
      directory,
      among: SessionDao(context.database).getAll(),
      directoriesOf: directoriesOf,
      pathsMatch: samePath,
      mayWrite: mayWrite,
      isLive: liveness.isLive,
      excluding: excluding,
    ))
      CheckoutOccupant(
        session: session,
        agentName: switch (installations.getById(session.agentInstallationId)) {
          final installation? => context.agents.displayNameFor(
            installation.agentId,
          ),
          null => null,
        },
      ),
  ];
}
