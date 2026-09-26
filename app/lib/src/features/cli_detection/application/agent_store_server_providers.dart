import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../agents/application/agent_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_signals.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../data/agent_store_servers.dart';

/// The app's live agent store-server connections, one per (environment,
/// agent). Lazy twice over, and disposed with the scope so quitting leaves no
/// server process behind.
final agentStoreServersProvider = Provider<AgentStoreServers>((ref) {
  final servers = AgentStoreServers(
    runnerFactory: ref.watch(commandRunnerFactoryProvider),
    environments: ref.watch(executionEnvironmentDaoProvider),
    installations: ref.watch(agentInstallationDaoProvider),
    registry: ref.watch(agentRegistryProvider),
    clientVersion: appVersion.isEmpty ? '0.0.0' : appVersion,
    onNameUpdated: (agentId, update) {
      final sessions = ref.read(sessionDaoProvider);
      final installations = ref.read(agentInstallationDaoProvider);
      final agentIdsByInstallation = <String, String?>{};
      var changed = false;
      for (final row in sessions.getAllByExternalSessionId(
        update.conversationId,
      )) {
        final rowAgentId = agentIdsByInstallation.putIfAbsent(
          row.agentInstallationId,
          () => installations.getById(row.agentInstallationId)?.agentId,
        );
        // A title the user typed here is never replaced: the agent owns the
        // name only until someone renames the row in Karmashala.
        if (rowAgentId != agentId ||
            row.title == update.name ||
            row.titleByUser) {
          continue;
        }
        sessions.updateTitle(row.id, update.name);
        ref
            .read(sessionsRevisionProvider.notifier)
            .changed(SessionChange.renamed(row.id));
        changed = true;
      }
      if (changed) {
        ref
            .read(terminalSessionsControllerProvider.notifier)
            .notifyTitleChanged();
      }
    },
  );
  ref.onDispose(servers.closeAll);
  return servers;
});
