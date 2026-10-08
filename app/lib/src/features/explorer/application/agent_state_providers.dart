import '../../workspaces/data/workspace_data.dart';
import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:riverpod/riverpod.dart';

import '../../notifications/application/attention_inbox.dart';
import '../../notifications/application/notification_providers.dart';
import '../../notifications/application/session_statuses.dart';
import '../../projects/application/projects_controller.dart';
import '../../sessions/application/background_runs_providers.dart';
import '../../sessions/application/session_last_active_providers.dart';
import '../../sessions/application/session_list_prefs.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_signals.dart';
import '../../sessions/application/session_status_providers.dart';
import 'agent_states.dart';
import 'hidden_working_sessions.dart';
import 'workspace_session_entry.dart';

/// The live statuses that decide a group — waiting, working, failed — per
/// workspace row, as the one registry reports them. Idle and unknown are left
/// out, so a turn ending elsewhere moves this map only if it held that row.
///
/// A subscription like `WorkingSessions`: it moves when a status does, and a
/// cycle that reconfirms every status moves nothing.
class LiveAgentStatuses extends Notifier<Map<String, AgentActivityStatus>> {
  @override
  Map<String, AgentActivityStatus> build() {
    final registry = ref.watch(sessionStatusRegistryProvider);
    final moves = registry.statusChanges.listen(_moved);
    final watched = registry.removals.listen((_) => _prune(registry));
    ref.onDispose(() {
      unawaited(moves.cancel());
      unawaited(watched.cancel());
    });
    return Map.unmodifiable({
      for (final entry in registry.entries)
        entry.session.openId: ?_grouping(
          registry.reportForOpenId(entry.session.openId)?.status,
        ),
    });
  }

  static AgentActivityStatus? _grouping(AgentActivityStatus? status) =>
      switch (status) {
        AgentActivityStatus.awaitingApproval ||
        AgentActivityStatus.working ||
        AgentActivityStatus.failed => status,
        _ => null,
      };

  void _moved(SessionStatusEntry entry) {
    final id = entry.session.openId;
    final next = _grouping(entry.report.status);
    if (state[id] == next) return;
    final copy = {...state};
    if (next == null) {
      copy.remove(id);
    } else {
      copy[id] = next;
    }
    state = Map.unmodifiable(copy);
  }

  /// A session that stops being watched leaves without a last status.
  void _prune(SessionStatuses registry) {
    if (state.isEmpty) return;
    final kept = {
      for (final MapEntry(key: id, value: status) in state.entries)
        if (_grouping(registry.reportForOpenId(id)?.status) == status)
          id: status,
    };
    if (kept.length != state.length) state = Map.unmodifiable(kept);
  }
}

final liveAgentStatusesProvider =
    NotifierProvider<LiveAgentStatuses, Map<String, AgentActivityStatus>>(
      LiveAgentStatuses.new,
    );

/// **The sessions waiting on the user**, keyed by workspace row id.
///
/// `NotificationReason.needsInput` — the status the app already labels "Needs
/// you": every session the attention inbox holds a needs-approval item for,
/// seen or not (looking at a question does not answer it, so the inbox keeps
/// it), and one the registry reports waiting before the watcher files it.
/// An unread finished turn is not one: that agent is ready, not blocked.
final needsYouProvider = Provider<Map<String, NeedsYouSource>>((ref) {
  final inbox = ref.watch(attentionInboxProvider);
  final live = ref.watch(liveAgentStatusesProvider);
  final byId = <String, NeedsYouSource>{};
  for (final item in inbox.items) {
    if (item.kind != InboxItemKind.needsApproval) continue;
    byId.putIfAbsent(
      item.session.openId,
      () => NeedsYouSource(
        label: item.session.label,
        imported: item.session.imported,
      ),
    );
  }
  if (live.containsValue(AgentActivityStatus.awaitingApproval)) {
    final registry = ref.read(sessionStatusRegistryProvider);
    for (final entry in registry.entries) {
      final id = entry.session.openId;
      if (live[id] != AgentActivityStatus.awaitingApproval) continue;
      byId.putIfAbsent(
        id,
        () => NeedsYouSource(
          label: entry.session.label,
          imported: entry.session.imported,
        ),
      );
    }
    // A hook can land before the cycle that lists its session.
    for (final MapEntry(key: id, value: status) in live.entries) {
      if (status != AgentActivityStatus.awaitingApproval) continue;
      byId.putIfAbsent(id, () => NeedsYouSource(label: id, imported: false));
    }
  }
  return Map.unmodifiable(byId);
});

/// The Agents entry's count. An `int`, so a change that moves no session in
/// or out of waiting wakes nothing that shows it.
final needsYouCountProvider = Provider<int>(
  (ref) => ref.watch(needsYouProvider).length,
);

/// Every session in the workspace, across projects — read only while a lens
/// that lists them is on screen, and again only when a row appears, goes,
/// moves, is renamed or changes lifecycle.
final workspaceSessionsProvider =
    Provider.autoDispose<List<WorkspaceSessionEntry>>((ref) {
      ref.watchSessionKinds(const {
        SessionChangeKind.membership,
        SessionChangeKind.title,
        SessionChangeKind.status,
        SessionChangeKind.placement,
        SessionChangeKind.workspace,
      });
      final projectNames = {
        for (final project in ref.watch(sortedProjectsProvider))
          project.id: project.name,
      };
      final repositories = {
        for (final repository in ref.read(workspaceDataProvider).repositories)
          repository.id: repository,
      };
      final lastActiveOf = ref.read(sessionLastActiveProvider);
      final showArchived = ref.watch(showArchivedSessionsProvider);
      final entries = <WorkspaceSessionEntry>[];
      for (final session in ref.read(sessionsDataProvider).getAll()) {
        if (session.isArchived && !showArchived) continue;
        final repository = repositories[session.repositoryId];
        entries.add(
          WorkspaceSessionEntry(
            id: session.id,
            title: session.title,
            createdAt: session.createdAt,
            projectName: projectNames[repository?.projectId],
            directory: session.worktree ?? repository?.path,
            lastActiveAt: lastActiveOf(session.id).at,
            native: session,
          ),
        );
      }
      for (final imported in ref.read(importedSessionsProvider).getAll()) {
        // A subagent's conversation is part of its parent's chat, not one of
        // the user's own.
        if (imported.isSubagent) continue;
        final repository = repositories[imported.repositoryId];
        entries.add(
          WorkspaceSessionEntry(
            id: imported.id,
            title: imported.displayTitle,
            createdAt: imported.createdAt,
            projectName: projectNames[repository?.projectId],
            directory: repository?.path,
            lastActiveAt: lastActiveOf(
              imported.id,
              storeModifiedAt: imported.updatedAt,
            ).at,
            imported: imported,
          ),
        );
      }
      return List.unmodifiable(entries);
    });

/// How many sessions are archived, for the "Archived (N)" row the lists end
/// with while they are hidden.
final archivedSessionCountProvider = Provider.autoDispose<int>((ref) {
  ref.watchSessionKinds(const {
    SessionChangeKind.membership,
    SessionChangeKind.status,
  });
  var count = 0;
  for (final session in ref.read(sessionsDataProvider).getAll()) {
    if (session.isArchived) count++;
  }
  return count;
});

/// Working sessions the server reads as quiet ([quietAt]). A quiet mark
/// coming or going leaves the status at `working`, which raises no grouping
/// event, so each working session's own status is watched for its mark alone
/// — no clock here: the server keeps the time.
final quietSessionsProvider = Provider.autoDispose<Set<String>>((ref) {
  final live = ref.watch(liveAgentStatusesProvider);
  return Set.unmodifiable({
    for (final MapEntry(key: id, value: status) in live.entries)
      if (status == AgentActivityStatus.working &&
          ref.watch(
            agentSessionStatusProvider(
              id,
            ).select((report) => quietAt(report.value) != null),
          ))
        id,
  });
});

/// The Agents page: every session by state. Recomputed when a session list
/// change, a grouping status move or a change in [quietSessionsProvider]
/// arrives — never on a clock of its own. With "Hide while working" on, the
/// sessions [hiddenWorkingSessionsProvider] holds are left out.
final agentStateGroupsProvider = Provider.autoDispose<List<AgentStateGroup>>((
  ref,
) {
  final hidden = ref.watch(hiddenWorkingSessionsProvider);
  final entries = ref.watch(workspaceSessionsProvider);
  return groupByAgentState(
    hidden.isEmpty
        ? entries
        : [
            for (final entry in entries)
              if (!hidden.contains(entry.id)) entry,
          ],
    needsYou: ref.watch(needsYouProvider),
    live: ref.watch(liveAgentStatusesProvider),
    quiet: ref.watch(quietSessionsProvider),
  );
});

/// How many sessions the Agents page's "N working" line stands for.
final agentsHiddenWorkingCountProvider = Provider.autoDispose<int>((ref) {
  final hidden = ref.watch(hiddenWorkingSessionsProvider);
  if (hidden.isEmpty) return 0;
  return hidden.countIn([
    for (final entry in ref.watch(workspaceSessionsProvider)) entry.id,
  ]);
});

/// The name of the project a session (native or imported) belongs to, or
/// null when it has none we know — for an ask that has to say where it is
/// from (board N1: "in karmashala-app" on the dock and the toast). Read on
/// demand rather than watched: a project renamed under an open ask is not
/// worth a subscription on every surface that shows one.
final sessionProjectNameProvider = Provider<String? Function(String sessionId)>(
  (ref) => (sessionId) {
    final repositoryId =
        ref.read(sessionsDataProvider).getById(sessionId)?.repositoryId ??
        ref.read(importedSessionsProvider).getById(sessionId)?.repositoryId;
    if (repositoryId == null) return null;
    final projectId = ref
        .read(workspaceDataProvider)
        .repository(repositoryId)
        ?.projectId;
    if (projectId == null) return null;
    for (final project in ref.read(sortedProjectsProvider)) {
      if (project.id == projectId) return project.name;
    }
    return null;
  },
);

/// Session [String]'s "still running" clause for its row, from the runs the
/// composer's strip lists, so it clears when the last run ends; null when
/// none runs.
final sessionStillRunningProvider = Provider.autoDispose
    .family<String?, String>(
      (ref, sessionId) => inFlightClause([
        for (final entry in ref.watch(sessionBackgroundRunsProvider(sessionId)))
          if (entry.run.state.isRunning) backgroundRunTitle(entry.run),
      ]),
    );
