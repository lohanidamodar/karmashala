import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_installations_controller.dart';
import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala_session/session.dart';
import '../../sessions/application/session_list_prefs.dart';
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

  /// The folded agent the filter's menu would offer for [id], or null. An id
  /// no descriptor claims is *unknown*: the menu is built from the registry,
  /// so a filter that hid rows it cannot offer to bring back would lose them.
  String? _nameable(String? id) =>
      id != null && registry.byId(id) != null ? registry.foldedIdOf(id) : null;
}

final sessionAgentsProvider = Provider<SessionAgents>(
  (ref) => SessionAgents(
    byInstallation: {
      for (final installation in ref.watch(
        agentInstallationsControllerProvider,
      ))
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
  // A filter saved before forms were folded may name a chat form.
  final registry = ref.watch(agentRegistryProvider);
  return ids.isEmpty
      ? AgentFilter.all
      : AgentFilter({for (final id in ids) registry.foldedIdOf(id)});
});

/// What one project's row shows, and how much of it the filter is holding back.
class VisibleSessions {
  const VisibleSessions({
    required this.sessions,
    required this.hidden,
    this.archived = 0,
  });

  final CheckoutSessions sessions;

  /// How many of the project's sessions the agent filter took off the list.
  /// Counted here because here it is free: a workspace-wide count in the header
  /// would sweep the session table for every project nobody has opened.
  final int hidden;

  /// How many archived sessions are off the list while they are hidden.
  final int archived;
}

/// Every session in a project that the agent filter admits, archived ones only
/// with "Show archived" on. Costs nothing while the agent filter is off: that
/// branch never mounts [sessionAgentsProvider].
final visibleProjectSessionsProvider = Provider.autoDispose
    .family<VisibleSessions, String>((ref, projectId) {
      var all = ref.watch(projectSessionsProvider(projectId));
      var archived = 0;
      if (!ref.watch(showArchivedSessionsProvider)) {
        final shown = [
          for (final session in all.native)
            if (!session.isArchived) session,
        ];
        archived = all.native.length - shown.length;
        if (archived > 0) {
          all = CheckoutSessions(native: shown, imported: all.imported);
        }
      }
      final filter = ref.watch(explorerAgentFilterProvider);
      if (filter.isUnfiltered) {
        return VisibleSessions(sessions: all, hidden: 0, archived: archived);
      }
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
        archived: archived,
      );
    });
