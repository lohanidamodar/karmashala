import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import '../../environments/application/environment_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_signals.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
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
    onThreadNameUpdated: (update) {
      final sessions = ref.read(sessionDaoProvider);
      final installations = ref.read(agentInstallationDaoProvider);
      final agentIdsByInstallation = <String, String?>{};
      var changed = false;
      for (final row in sessions.getAllByExternalSessionId(update.threadId)) {
        final agentId = agentIdsByInstallation.putIfAbsent(
          row.agentInstallationId,
          () => installations.getById(row.agentInstallationId)?.agentId,
        );
        // A title the user typed here is never replaced — the same rule the
        // slow title sync keeps. Codex owns the name only until someone
        // renames the row in Karmashala.
        if (agentId != AgentIds.codex ||
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
