import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_installations_controller.dart';
import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import '../../sessions/domain/session.dart';
import '../../settings/application/settings_controller.dart';
import '../domain/agent_filter.dart';
import 'project_tree.dart';

/// Which agent runs a session, answered without asking per session: the only
/// lookup is installation → agent, and that table is one row per
/// `(agent, environment)`, read whole from a controller mounted at startup.
class SessionAgents {
  const SessionAgents({required this.byInstallation, required this.registry});

  /// Installation id → `AgentDescriptor.id`.
  final Map<String, String> byInstallation;

  final AgentRegistry registry;

  /// The agent behind a native session, or null when the workspace cannot say.
  String? forNative(Session session) =>
      _nameable(byInstallation[session.agentInstallationId]);

  /// The agent behind an imported conversation, or null when the workspace
  /// cannot say.
  String? forImported(ImportedSession session) => _nameable(session.cli);

  /// An id the filter's menu could actually offer, or null. An id no descriptor
  /// claims is *unknown*: the menu is built from the registry, so a filter that
  /// hid rows it cannot offer to bring back would lose them.
  String? _nameable(String? id) =>
      id != null && registry.byId(id) != null ? id : null;
}

final sessionAgentsProvider = Provider<SessionAgents>(
  (ref) => SessionAgents(
    byInstallation: {
      for (final installation in ref.watch(agentInstallationsControllerProvider))
        installation.id: installation.agentId,
    },
    registry: ref.watch(agentRegistryProvider),
  ),
);

/// The agents the Explorer is currently showing. It survives a restart, paid
/// for by a filled funnel that names what is off the list. The `Set` is built
/// here, not in the selector — `select` compares with `==`.
final explorerAgentFilterProvider = Provider<AgentFilter>((ref) {
  final ids = ref.watch(
    settingsControllerProvider.select((s) => s.explorerAgentFilter),
  );
  return ids.isEmpty ? AgentFilter.all : AgentFilter(ids.toSet());
});

/// What one project's row shows, and how much of it the filter is holding back.
class VisibleSessions {
  const VisibleSessions({required this.sessions, required this.hidden});

  final CheckoutSessions sessions;

  /// How many of the project's sessions the agent filter took off the list.
  /// Counted here because here it is free: a workspace-wide count in the header
  /// would sweep the session table for every project nobody has opened.
  final int hidden;
}

/// Every session in a project that the agent filter admits. Costs nothing while
/// the filter is off: the unfiltered branch hands back [projectSessionsProvider]'s
/// own list and never mounts [sessionAgentsProvider].
final visibleProjectSessionsProvider = Provider.autoDispose
    .family<VisibleSessions, String>((ref, projectId) {
      final all = ref.watch(projectSessionsProvider(projectId));
      final filter = ref.watch(explorerAgentFilterProvider);
      if (filter.isUnfiltered) {
        return VisibleSessions(sessions: all, hidden: 0);
      }
      final agents = ref.watch(sessionAgentsProvider);
      final native = [
        for (final session in all.native)
          if (filter.allows(agents.forNative(session))) session,
      ];
      final imported = [
        for (final session in all.imported)
          if (filter.allows(agents.forImported(session))) session,
      ];
      return VisibleSessions(
        sessions: CheckoutSessions(native: native, imported: imported),
        hidden: all.length - native.length - imported.length,
      );
    });
