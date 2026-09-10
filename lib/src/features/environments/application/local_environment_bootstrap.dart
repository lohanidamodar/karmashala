import 'package:karmashala_core/util.dart';
import '../data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';

/// Ensures the always-present local host execution environment row exists.
/// Idempotent; returns the environment id.
String ensureLocalEnvironment(ExecutionEnvironmentDao dao, Clock clock) {
  if (dao.getById(localHostEnvironmentId) == null) {
    dao.upsert(localHostEnvironment(clock.nowUtc()));
  }
  return localHostEnvironmentId;
}
