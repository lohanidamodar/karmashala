import 'package:agent_cli/process.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../data/execution_environment_dao.dart';

/// Repository-layer provider for execution-environment persistence.
final executionEnvironmentDaoProvider = Provider<ExecutionEnvironmentDao>(
  (ref) => ExecutionEnvironmentDao(ref.watch(databaseProvider)),
);

/// This machine's own environment row, or null before discovery has written
/// one. Swept once and shared: callers used to run `getAll` per project, which
/// is a table scan a row at a time.
final localEnvironmentProvider = Provider<ExecutionEnvironment?>(
  (ref) => ref
      .watch(executionEnvironmentDaoProvider)
      .getAll()
      .where(
        (e) =>
            e.kind == EnvironmentKind.windowsNative ||
            e.kind == EnvironmentKind.localPosix,
      )
      .firstOrNull,
);
