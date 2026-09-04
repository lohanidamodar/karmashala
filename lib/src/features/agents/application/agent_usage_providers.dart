import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../explorer/application/session_context.dart';
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
/// failure until something asks again.
///
/// **A first build is answered from memory when it can be.** `autoDispose` plus
/// a family key means this provider is created afresh every time the focused
/// pane moves to another account and back, and each creation used to be an
/// unconditional request — the one trigger no interval bounded. `isFirstBuild`
/// is exactly the case Riverpod documents as "the state was destroyed and later
/// recreated", so a pane switch now costs a request only when the reading the
/// app already holds has aged past one interval. A tick or a click is not a
/// first build and always asks.
final agentUsageProvider = FutureProvider.autoDispose
    .family<AgentUsage, AgentInstallation>((ref, installation) async {
      final service = ref.watch(agentUsageServiceProvider);
      if (ref.isFirstBuild) {
        final remembered = service.rememberedIfFresh(installation);
        if (remembered != null) return remembered;
      }
      final environments = ref.watch(executionEnvironmentDaoProvider).getAll();
      return service.fetch(installation, environments);
    }, retry: (_, _) => null);

/// The installation whose quota the app chrome should be showing: the agent
/// behind the session you are looking at.
///
/// Null — and therefore **no chip at all** — when nothing is selected, or when
/// the selected session's agent is not one of the two whose usage endpoint
/// [AgentUsageService] speaks. That is the same allowlist the service enforces,
/// applied one step earlier so an Antigravity pane shows nothing rather than an
/// error the user can do nothing about.
///
/// Watches membership and placement only: a session's agent installation
/// cannot change under a rename or a status transition, and this sits in a row
/// that redraws on every shell change already.
final focusedUsageInstallationProvider =
    Provider.autoDispose<AgentInstallation?>((ref) {
      ref.watchSessionKinds(const {
        SessionChangeKind.membership,
        SessionChangeKind.placement,
      });
      final sessionId = ref.watch(focusedSessionIdProvider);
      if (sessionId == null) return null;
      final session = ref.read(sessionDaoProvider).getById(sessionId);
      if (session == null) return null;
      for (final installation in ref.watch(
        agentInstallationsControllerProvider,
      )) {
        if (installation.id != session.agentInstallationId) continue;
        final agentId = installation.agentId;
        return agentId == AgentIds.claudeCode || agentId == AgentIds.codex
            ? installation
            : null;
      }
      return null;
    });
