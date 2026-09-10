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

/// Fetches live usage/limits for an agent installation.
final agentUsageServiceProvider = Provider<AgentUsageService>(
  (ref) => AgentUsageService(
    storeLocator: ref.watch(cliStoreLocatorProvider),
    clock: ref.watch(agentCliClockProvider),
  ),
);

/// Live usage for one installation, fetched on demand. `autoDispose` so it
/// refetches when re-viewed rather than caching a stale snapshot; invalidate to
/// force a refresh.
///
/// **Every build is answered from memory when it can be, and the check is not
/// here**: it lives in [AgentUsageService.fetch], where all six paths pass it. A
/// `ref.isFirstBuild` guard bounded only the pane switch, because every other
/// trigger arrives through `ref.invalidate` — a rebuild, not a mount.
///
/// **Retry is off deliberately.** Riverpod's default would re-run a failed fetch
/// ten times with exponential backoff on its own timer, focused or not: a second
/// polling loop behind the one `UsageRefreshController` owns, hitting the vendor
/// endpoint with an expired token while the user is away. A failure stays a
/// failure until something asks again.
final agentUsageProvider = FutureProvider.autoDispose
    .family<AgentUsage, AgentInstallation>((ref, installation) {
      final service = ref.watch(agentUsageServiceProvider);
      final environments = ref.watch(executionEnvironmentDaoProvider).getAll();
      return service.fetch(installation, environments);
    }, retry: (_, _) => null);

/// **Whose quota one session is spending**: the installation behind [sessionId],
/// when we speak its agent's usage endpoint.
///
/// Keyed by session rather than derived from whatever the app believes is
/// focused: `focusedSessionIdProvider` used to decide which account the window's
/// status bar reported, so a workspace with a Claude pane and a Codex pane
/// showed one figure for both, and a click in the tree changed whose number it
/// was without changing the pane being typed in.
///
/// Null — and therefore **no chip at all** — when the row has gone, or when its
/// agent is not one whose usage endpoint [AgentUsageService] speaks. Nothing is
/// the answer on purpose: a dash would read as a reading. Watches membership
/// only, because a row's `agentInstallationId` never moves and a re-detection is
/// the one thing that can change this.
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
