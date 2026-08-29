import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../data/agent_installation_dao.dart';
import '../domain/agent_registry.dart';

/// Repository-layer provider for agent-installation persistence.
final agentInstallationDaoProvider = Provider<AgentInstallationDao>(
  (ref) => AgentInstallationDao(ref.watch(databaseProvider)),
);

/// The agents the app knows about. Overridable in tests to probe a custom set.
final agentRegistryProvider = Provider<AgentRegistry>(
  (ref) => AgentRegistry.builtIn,
);
