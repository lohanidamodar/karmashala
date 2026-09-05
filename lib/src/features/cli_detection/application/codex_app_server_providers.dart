import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/build_identity.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../agents/application/agent_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../data/codex_app_servers.dart';

/// The app's live `codex app-server` connections, one per environment.
///
/// Lazy twice over: the pool starts nothing, and a connection is only spawned
/// by the first call made on it. Disposed with the scope so quitting leaves no
/// `codex` process behind.
final codexAppServersProvider = Provider<CodexAppServers>((ref) {
  final servers = CodexAppServers(
    runnerFactory: ref.watch(commandRunnerFactoryProvider),
    environments: ref.watch(executionEnvironmentDaoProvider),
    installations: ref.watch(agentInstallationDaoProvider),
    clientVersion: appVersion.isEmpty ? '0.0.0' : appVersion,
  );
  ref.onDispose(servers.closeAll);
  return servers;
});
