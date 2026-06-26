import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../data/agent_installation_dao.dart';

/// Repository-layer provider for agent-installation persistence.
final agentInstallationDaoProvider = Provider<AgentInstallationDao>(
  (ref) => AgentInstallationDao(ref.watch(databaseProvider)),
);
