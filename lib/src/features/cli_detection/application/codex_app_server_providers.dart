import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/build_identity.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/domain/agent_ids.dart';
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
        if (agentId != AgentIds.codex || row.title == update.name) {
          continue;
        }
        // An explicit Codex-side rename is the newest choice. Passing false
        // leaves the title open to a later rename from Codex as well.
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
