import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../data/repository_dao.dart';

/// Repository-layer provider for Git-repository persistence.
final repositoryDaoProvider = Provider<RepositoryDao>(
  (ref) => RepositoryDao(ref.watch(databaseProvider)),
);
