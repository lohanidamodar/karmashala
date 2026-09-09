import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../data/agent_usage_service.dart';
import '../domain/agent_ids.dart';
import '../domain/agent_installation.dart';
import '../domain/agent_usage.dart';
import 'agent_installations_controller.dart';

/// Fetches live usage/limits for an agent installation.
final agentUsageServiceProvider = Provider<AgentUsageService>(
  (ref) => AgentUsageService(
    storeLocator: ref.watch(cliStoreLocatorProvider),
    clock: ref.watch(clockProvider),
  ),
);

/// Live usage for one installation, fetched on demand. `autoDispose` so it
/// refetches when re-viewed rather than caching a stale snapshot; invalidate to
/// force a refresh.
///
/// **Retry is off deliberately.** Riverpod's default would re-run a failed
/// fetch ten times with exponential backoff, on its own timer, whether or not
/// the window has focus — a second polling loop behind the one
/// `UsageRefreshController` owns, and one that would keep hitting the vendor
/// endpoint with an expired token while the user is away. A failure stays a
/// **Every build is answered from memory when it can be**, and the check is
/// not here.
///
/// It used to be, guarded by `ref.isFirstBuild`, and that bounded exactly one
/// trigger. `isFirstBuild` is true only when Riverpod *mounts* the element — a
/// pane switch, because `autoDispose` plus a family key destroys and recreates
/// this provider as the account on screen changes. Every other trigger reaches
/// here through `ref.invalidate`, which is a rebuild and not a mount, so the
/// tick, the chip's click and a session's status moving each went straight to
/// the vendor however recently the app had read the number. The floor now lives
/// in [AgentUsageService.fetch], where all six paths pass it.
///
/// **Retry is off deliberately.** Riverpod's default would re-run a failed
/// fetch ten times with exponential backoff, on its own timer, whether or not
/// the window has focus — a second polling loop behind the one
/// `UsageRefreshController` owns, and one that would keep hitting the vendor
/// endpoint with an expired token while the user is away. A failure stays a
/// failure until something asks again.
final agentUsageProvider = FutureProvider.autoDispose
    .family<AgentUsage, AgentInstallation>((ref, installation) {
      final service = ref.watch(agentUsageServiceProvider);
      final environments = ref.watch(executionEnvironmentDaoProvider).getAll();
      return service.fetch(installation, environments);
    }, retry: (_, _) => null);

/// **Whose quota one session is spending**: the installation behind
/// [sessionId], when we speak its agent's usage endpoint.
///
/// Keyed by session rather than derived from whatever the app believes is
/// focused, because the two are not the same question and the app was answering
/// the wrong one. `focusedSessionIdProvider` — the Explorer's selection, then
/// the active pane — decided which account the window's status bar reported,
/// so a workspace with a Claude pane and a Codex pane showed one figure for
/// both, and a click in the tree could change which account the number belonged
/// to without changing the pane the user was typing in. Panes run different
/// agents and different accounts; each pane's chip now asks about its own.
///
/// Null — and therefore **no chip at all** — when the row has gone, or when its
/// agent is not one of the three whose usage endpoint [AgentUsageService]
/// speaks. That is the same allowlist the service enforces, applied one step
/// earlier so a pane on an agent we have no endpoint for shows nothing rather
/// than an error the user can do nothing about. Nothing is the answer on
/// purpose: a dash would read as a reading.
///
/// Watches membership only. A row's `agentInstallationId` is written when it is
/// created and never moves, so a rename, a status transition or a pane change
/// cannot alter this answer; the installation list is watched for the one thing
/// that can, a re-detection.
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
