import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../data/execution_environment_dao.dart';

/// Repository-layer provider for execution-environment persistence.
final executionEnvironmentDaoProvider = Provider<ExecutionEnvironmentDao>(
  (ref) => ExecutionEnvironmentDao(ref.watch(databaseProvider)),
);
