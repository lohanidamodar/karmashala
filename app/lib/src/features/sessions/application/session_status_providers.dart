import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import '../../notifications/application/notification_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_runtime/screen_reading.dart';
import 'package:karmashala_session/session.dart';
import 'session_providers.dart';
import 'session_signals.dart';

/// What one session's agent is doing — a projection of the one shared registry,
/// starting nothing. [AgentActivityStatus.unknown] is a first-class answer.
final agentSessionStatusProvider = StreamProvider.autoDispose
    .family<AgentStatusReport, String>(
      (ref, sessionId) =>
          ref.watch(sessionStatusRegistryProvider).reportsFor(sessionId),
    );

/// One session's status, read synchronously for a decision being made now: a
/// function, not a `family`, so a `read` is never handed a cached first answer.
final sessionActivityLookupProvider =
    Provider<AgentActivityStatus Function(String sessionId)>(
      (ref) =>
          (sessionId) =>
              ref.read(sessionStatusLookupProvider)(sessionId)?.status ??
              AgentActivityStatus.unknown,
    );

/// One session's whole report, read synchronously, for `session_send`, which
/// must not type into an open prompt. Null is *unknown*, not either state.
final sessionStatusLookupProvider =
    Provider<AgentStatusReport? Function(String sessionId)>(
      (ref) =>
          (sessionId) => ref
              .read(sessionStatusRegistryProvider)
              .reportForOpenId(sessionId),
    );

/// One session's status now and every later change — the signal a wait ends on.
/// A wait wants a subscription it opens and closes, not one it might inherit.
final sessionStatusStreamProvider =
    Provider<Stream<AgentStatusReport> Function(String sessionId)>(
      (ref) =>
          (sessionId) =>
              ref.read(sessionStatusRegistryProvider).reportsFor(sessionId),
    );

/// paneId → the session standing in it. One shared producer, watched on
/// **placement alone**, so the app's most frequent change never wakes a tab.
final placedSessionIdsProvider = Provider<Map<String, String>>((ref) {
  ref.watchSessionKinds(const {SessionChangeKind.placement});
  return ref.read(sessionsDataProvider).paneSessionIds();
});

/// The panes on screen right now. Pane ids, not session ids: resolving them
/// costs a table scan the inbox does not need while it holds no items.
final foregroundTerminalPaneIdsProvider = Provider<List<String>>((ref) {
  // Asked through `exists`, never built: building the controller starts the
  // scrollback autosave timer, which every reader would inherit as a pending.
  if (!ref.exists(terminalSessionsControllerProvider)) return const [];
  // **Every group showing its terminal**, not just the focused one: a pane the
  // user can see is a pane the inbox must not badge.
  final faces = ref.watch(terminalFacesProvider);
  final joined = ref.watch(
    terminalSessionsControllerProvider.select((state) {
      final tree = state.workspace;
      if (tree == null) return '';
      final byTab = {for (final tab in state.tabs) tab.id: tab};
      return [
        for (final group in tree.groups)
          if (faces[group.id] ?? true)
            if (byTab[group.activePaneId] case final tab?)
              ...tab.layout.visiblePanes,
      ].join('\u0000');
    }),
  );
  return joined.isEmpty ? const [] : joined.split('\u0000');
});

/// What the agent in pane [paneId] is doing, or null when it has no agent.
/// The session id comes from the **row**, so an adopted shell pane is included.
final paneAgentActivityProvider = Provider.autoDispose
    .family<AgentActivityStatus?, String>((ref, paneId) {
      if (!ref.watch(terminalPaneLivenessProvider(paneId)).isLive) return null;
      final sessionId = ref.watch(
        placedSessionIdsProvider.select((byPane) => byPane[paneId]),
      );
      if (sessionId == null) return null;
      return ref.watch(
            agentSessionStatusProvider(
              sessionId,
            ).select((report) => report.value?.status),
          ) ??
          AgentActivityStatus.unknown;
    });

/// The one status a chip standing for several panes shows, ordered by **what
/// the user must do about it**. Null when no pane in the group has an agent.
AgentActivityStatus? mostUrgentAgentActivity(
  Iterable<AgentActivityStatus?> statuses,
) {
  AgentActivityStatus? strongest;
  for (final status in statuses) {
    if (status == null) continue;
    if (strongest == null || _urgency(status) > _urgency(strongest)) {
      strongest = status;
    }
  }
  return strongest;
}

int _urgency(AgentActivityStatus status) => switch (status) {
  AgentActivityStatus.awaitingApproval => 4,
  AgentActivityStatus.failed => 3,
  AgentActivityStatus.working => 2,
  AgentActivityStatus.idle => 1,
  AgentActivityStatus.unknown => 0,
};

/// The bottom rows of the pane [session] runs in, empty rather than absent for
/// a dead one. [agentId] picks the depth; these rows are quoted as the prompt.
List<String> sessionTerminalTail(Ref ref, Session session, {String? agentId}) {
  return sessionTerminalTailForPane(ref, session.paneId, agentId: agentId);
}

/// The bottom rows of [paneId], or nothing when it is absent or dead — the
/// row-free form, so the registry's loader need not re-query the row.
List<String> sessionTerminalTailForPane(
  Ref ref,
  String? paneId, {
  String? agentId,
}) {
  if (paneId == null) return const [];
  final instance = ref
      .read(terminalSessionsControllerProvider.notifier)
      .instanceFor(paneId);
  if (instance == null || !instance.liveness.value.isLive) return const [];
  final rules = agentId == null
      ? null
      : ref.read(agentRegistryProvider).byId(agentId)?.grid;
  return terminalTailLines(
    instance.terminal,
    lines: rules?.scanLines ?? const AgentGridRules().scanLines,
  );
}
