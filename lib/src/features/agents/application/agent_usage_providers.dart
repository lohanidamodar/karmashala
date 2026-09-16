import 'package:riverpod/riverpod.dart';

import '../../../core/util/agent_cli_bridge.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import 'package:agent_cli/usage.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'agent_installations_controller.dart';
import 'usage_history.dart';

/// Fetches live usage/limits for an agent installation. Every fresh reading is
/// written to the usage history.
final agentUsageServiceProvider = Provider<AgentUsageService>((ref) {
  final service = AgentUsageService(
    storeLocator: ref.watch(cliStoreLocatorProvider),
    clock: ref.watch(agentCliClockProvider),
  );
  // Read lazily: the store is only needed once a reading actually arrives.
  service.addReadingListener(
    (installation, usage) => ref
        .read(usageHistoryRecorderProvider)
        .record(usageAccountKey(installation), usage),
  );
  return service;
});

/// Live usage for one installation, on demand. **Retry is off**: it would be a
/// second polling loop, 401ing with an expired token while nobody is there.
final agentUsageProvider = FutureProvider.autoDispose
    .family<AgentUsage, AgentInstallation>((ref, installation) {
      final service = ref.watch(agentUsageServiceProvider);
      final environments = ref.watch(executionEnvironmentDaoProvider).getAll();
      return service.fetch(installation, environments);
    }, retry: (_, _) => null);

/// **Whose quota one session is spending**: keyed by session, not by whatever
/// is focused. Null — and no chip at all — for an agent with no endpoint.
final usageInstallationForSessionProvider = Provider.autoDispose
    .family<AgentInstallation?, String>((ref, sessionId) {
      ref.watchSessionKinds(const {SessionChangeKind.membership});
      final session = ref.read(sessionDaoProvider).getById(sessionId);
      if (session == null) return null;
      for (final installation in ref.watch(
        agentInstallationsControllerProvider,
      )) {
        if (installation.id != session.agentInstallationId) continue;
        final agentId = installation.agentId;
        return agentId == AgentIds.claudeCode ||
                agentId == AgentIds.codex ||
                agentId == AgentIds.antigravity
            ? installation
            : null;
      }
      return null;
    });
