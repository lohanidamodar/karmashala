import 'dart:io' show Platform;

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

/// The host process's environment variables.
///
/// Behind a provider so tests can be hermetic: discovery expands the
/// descriptors' declared Windows install paths against this, and a test that
/// silently inherited the developer's real `%LOCALAPPDATA%` would probe
/// different files on different machines.
final hostEnvironmentProvider = Provider<Map<String, String>>(
  (ref) => Platform.environment,
);
