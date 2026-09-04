import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/application/agent_installations_controller.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/domain/agent_registry.dart';
import '../../cli_detection/domain/imported_session.dart';
import '../../sessions/domain/session.dart';
import '../../settings/application/settings_controller.dart';
import '../domain/agent_filter.dart';
import 'project_tree.dart';

/// **Which agent runs a session, answered without asking per session.**
///
/// Agent identity lives in two places and neither is on the session row:
///
/// * a **native** session names an `agent_installations` row
///   ([Session.agentInstallationId]), and that row's `agent_kind` column holds
///   the `AgentDescriptor.id`;
/// * an **imported** conversation names the CLI that wrote it directly, in
///   [ImportedSession.cli], which is the same id spelling.
///
/// So the only lookup the filter needs is installation → agent, and that table
/// is one row per `(agent, environment)` — three agents across Windows and WSL
/// is six rows, not one per session. Read whole, once, from
/// [agentInstallationsControllerProvider], which the app already mounts at
/// startup: on a running app this resolver costs **nothing**, and on a bare
/// Explorer it costs one statement, flat in the size of the workspace.
///
/// The alternative was already in the tree and is exactly what this avoids:
/// `session_rows.dart` calls `AgentInstallationDao.getById` per card to label
/// one row. That is affordable for the cards actually on screen and would not
/// have been affordable as the basis of a filter, which has to have an opinion
/// about every session in the list.
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

  /// An id the filter's menu could actually offer, or null.
  ///
  /// An id no descriptor claims is reported as *unknown* rather than passed
  /// through, and that is the honesty rule rather than tidiness: the menu is
  /// built from the registry, so an id outside it can never be ticked, and a
  /// filter that hid rows it cannot offer to bring back would lose them. See
  /// [AgentFilter.allows].
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

/// The agents the Explorer is currently showing.
///
/// **It survives a restart**, and that is a deliberate trade rather than the
/// path of least resistance. An owner who runs three CLIs side by side and
/// narrows to one is in the middle of something that outlasts a window; a
/// narrowing that reset every launch would be re-applied every launch, which is
/// the annoyance the setting exists to remove. The trap a persisted filter sets
/// — coming back tomorrow to a list that is quietly missing two thirds of the
/// work — is paid for on the other side, in the header: the funnel is *filled*
/// while a narrowing is in force and its tooltip names the agents that are off
/// the list, and a project whose rows are all hidden says so in words where the
/// rows would have been. A filter you can see is a filter you can persist.
///
/// Selected out of settings rather than watched whole, so an unrelated write —
/// a pane width, a theme — does not rebuild the Explorer's tree. The `Set` is
/// built here rather than inside the selector for the reason
/// [explorerSectionAssignmentProvider] gives: `select` compares with `==`, and
/// a fresh collection is never equal to the last one.
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
  ///
  /// **The count is here rather than in the header** because here is where it
  /// is free. The tree only reads the projects the user has expanded, so this
  /// provider already holds every session it is counting; a workspace-wide
  /// "3 sessions hidden" in the header would mean sweeping the session table
  /// for every project the user has *not* opened, which is the per-workspace
  /// read this feature is not allowed to make. The header names the hidden
  /// agents instead, and the count is said where the rows are missing.
  final int hidden;
}

/// Every session in a project that the agent filter admits.
///
/// Costs the filter nothing when it is off: the unfiltered branch hands back
/// the very list [projectSessionsProvider] built, and never mounts
/// [sessionAgentsProvider], so the Explorer adds no statement at all until a
/// narrowing is actually in force. With it on the bill is one read of the
/// installations table for the whole panel, and a pass over a list already in
/// memory.
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
