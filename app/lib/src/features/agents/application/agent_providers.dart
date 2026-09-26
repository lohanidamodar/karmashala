import 'dart:io' show Platform;

import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/descriptors.dart';

export '../data/agents_data.dart'
    show AgentInstallationsData, agentInstallationsDataProvider;

/// The agents the app knows about. Overridable in tests to probe a custom set.
final agentRegistryProvider = Provider<AgentRegistry>(
  (ref) => AgentRegistry.builtIn,
);

/// The host process's environment variables, behind a provider so a test cannot
/// silently inherit the developer's real `%LOCALAPPDATA%`.
final hostEnvironmentProvider = Provider<Map<String, String>>(
  (ref) => Platform.environment,
);
