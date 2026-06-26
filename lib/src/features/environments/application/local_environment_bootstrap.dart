import '../../../core/util/clock.dart';
import '../data/execution_environment_dao.dart';
import '../domain/local_environment.dart';

/// Ensures the always-present local Windows execution environment row exists.
///
/// Idempotent: safe to call on every startup. Returns the environment id.
/// (Full environment discovery — WSL distributions, etc. — arrives in Loop 3.)
String ensureLocalEnvironment(ExecutionEnvironmentDao dao, Clock clock) {
  if (dao.getById(localWindowsEnvironmentId) == null) {
    dao.upsert(localWindowsEnvironment(clock.nowUtc()));
  }
  return localWindowsEnvironmentId;
}
