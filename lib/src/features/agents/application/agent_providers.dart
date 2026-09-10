import 'dart:io' show Platform;

import 'package:riverpod/riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';

/// Repository-layer provider for agent-installation persistence.
final agentInstallationDaoProvider = Provider<AgentInstallationDao>(
  (ref) => AgentInstallationDao(ref.watch(databaseProvider)),
);

/// The agents the app knows about. Overridable in tests to probe a custom set.
final agentRegistryProvider = Provider<AgentRegistry>(
  (ref) => AgentRegistry.builtIn,
);

/// The host process's environment variables, behind a provider so a test cannot
/// silently inherit the developer's real `%LOCALAPPDATA%`.
final hostEnvironmentProvider = Provider<Map<String, String>>(
  (ref) => Platform.environment,
);
