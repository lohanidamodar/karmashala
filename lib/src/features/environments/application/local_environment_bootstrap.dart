import 'package:karmashala_core/util.dart';
import '../data/execution_environment_dao.dart';
import '../domain/local_environment.dart';

/// Ensures the always-present local host execution environment row exists.
///
/// Idempotent: safe to call on every startup. Returns the environment id.
/// (Full environment discovery — WSL distributions, etc. — arrives in Loop 3.)
String ensureLocalEnvironment(ExecutionEnvironmentDao dao, Clock clock) {
  if (dao.getById(localHostEnvironmentId) == null) {
    dao.upsert(localHostEnvironment(clock.nowUtc()));
  }
  return localHostEnvironmentId;
}
