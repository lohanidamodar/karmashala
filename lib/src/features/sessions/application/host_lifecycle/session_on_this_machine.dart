import 'package:agent_cli/process.dart';
import 'package:karmashala_session/session.dart';

import '../../../environments/data/execution_environment_dao.dart';
import '../../../repositories/data/repository_dao.dart';

/// Whether [session] runs on this machine — Windows, WSL or the local POSIX
/// host — and so under this machine's session host. False for SSH, and for a
/// row whose environment cannot be found: no local fact can speak for it.
bool sessionRunsOnThisMachine(
  Session session, {
  required RepositoryDao repositories,
  required ExecutionEnvironmentDao environments,
}) {
  final environmentId =
      session.workingDirectory?.environmentId ??
      repositories.getById(session.repositoryId)?.path.environmentId;
  if (environmentId == null) return false;
  final kind = environments.getById(environmentId)?.kind;
  return kind != null && kind != EnvironmentKind.ssh;
}
