import 'package:agent_cli/process.dart';
import 'package:karmashala_session/session.dart';

/// Whether [session] runs on this machine — Windows, WSL or the local POSIX
/// host — and so under this machine's session host. False for SSH, and for a
/// row whose environment cannot be found: no local fact can speak for it.
///
/// [environmentOfRepository] and [kindOf] are the reader's lookups — the
/// store's tables at the server, the copies in a client.
bool runsOnThisMachine(
  Session session, {
  required String? Function(String repositoryId) environmentOfRepository,
  required EnvironmentKind? Function(String environmentId) kindOf,
}) {
  final environmentId =
      session.workingDirectory?.environmentId ??
      environmentOfRepository(session.repositoryId);
  if (environmentId == null) return false;
  final kind = kindOf(environmentId);
  return kind != null && kind != EnvironmentKind.ssh;
}
