import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../data/workspace_dao.dart';

/// Repository-layer provider for workspace persistence.
final workspaceDaoProvider = Provider<WorkspaceDao>(
  (ref) => WorkspaceDao(ref.watch(databaseProvider)),
);
