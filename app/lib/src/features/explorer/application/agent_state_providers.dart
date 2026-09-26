import '../../workspaces/data/workspace_data.dart';
import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:riverpod/riverpod.dart';
import '../../../core/util/clock_provider.dart';

import '../../cli_detection/application/cli_detection_providers.dart';
import '../../notifications/application/attention_inbox.dart';
import '../../notifications/application/notification_providers.dart';
import '../../notifications/application/session_status_registry.dart';
import '../../projects/application/projects_controller.dart';
import '../../sessions/application/session_last_active_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_signals.dart';
import '../../sessions/application/session_status_providers.dart';
import 'agent_states.dart';
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
    final watched = registry.coverageReports.listen((_) => _prune(registry));
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
  void _prune(SessionStatusRegistry registry) {
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
      final entries = <WorkspaceSessionEntry>[];
      for (final session in ref.read(sessionDaoProvider).getAll()) {
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
      for (final imported in ref.read(importedSessionDaoProvider).getAll()) {
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

/// Working sessions whose evidence has gone quiet ([quietAt]). Recomputed when
/// a grouping status move arrives, and at the moment the next working session
/// would turn quiet — one timer for that instant, not a tick.
///
/// A quiet session is re-read each minute while something shows one: new
/// evidence that leaves its status at `working` raises no event, so nothing
/// else would move it back.
final quietSessionsProvider = Provider.autoDispose<Set<String>>((ref) {
  final live = ref.watch(liveAgentStatusesProvider);
  final statusOf = ref.read(sessionStatusLookupProvider);
  final now = ref.read(clockProvider).nowUtc();

  final quiet = <String>{};
  DateTime? nextWake;
  for (final MapEntry(key: id, value: status) in live.entries) {
    if (status != AgentActivityStatus.working) continue;
    final at = quietAt(statusOf(id));
    if (at == null) continue;
    final isQuiet = !at.isAfter(now);
    if (isQuiet) quiet.add(id);
    final wake = isQuiet ? now.add(const Duration(minutes: 1)) : at;
    if (nextWake == null || wake.isBefore(nextWake)) nextWake = wake;
  }
  if (nextWake != null) {
    final timer = Timer(nextWake.difference(now), ref.invalidateSelf);
    ref.onDispose(timer.cancel);
  }
  return Set.unmodifiable(quiet);
});

/// The Agents page: every session by state. Recomputed when a session list
/// change, a grouping status move or a change in [quietSessionsProvider]
/// arrives — never on a clock of its own.
final agentStateGroupsProvider = Provider.autoDispose<List<AgentStateGroup>>(
  (ref) => groupByAgentState(
    ref.watch(workspaceSessionsProvider),
    needsYou: ref.watch(needsYouProvider),
    live: ref.watch(liveAgentStatusesProvider),
    quiet: ref.watch(quietSessionsProvider),
  ),
);
