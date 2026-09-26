import 'package:riverpod/riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../data/project_dao.dart';

/// Repository-layer provider for project persistence.
final projectDaoProvider = Provider<ProjectDao>(
  (ref) => ProjectDao(ref.watch(databaseProvider)),
);
