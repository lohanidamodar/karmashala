import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import '../../notifications/application/notification_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../../terminal/data/terminal_grid_text.dart';
import '../domain/session.dart';
import 'session_providers.dart';
import 'session_signals.dart';

/// What one session's agent is doing — a **projection**, and nothing more. It
/// selects a cached entry from `SessionStatusRegistry` and starts nothing: no
/// timer, no filesystem access, no store scan, so a hundred badges are a
/// hundred subscriptions to one broadcast that fires only when a session's
/// evidence changes. It used to be a per-badge 1.2-second poll, which made
/// status cost a side effect of layout.
///
/// Resolves to [AgentActivityStatus.unknown], immediately, for a session with
/// no pane and no hook — a first-class answer, not a failure.
final agentSessionStatusProvider = StreamProvider.autoDispose
    .family<AgentStatusReport, String>(
      (ref, sessionId) =>
          ref.watch(sessionStatusRegistryProvider).reportsFor(sessionId),
    );

/// **One session's status, read synchronously, for a decision being made now.**
///
/// A function behind a provider rather than a `family`: a family caches per
/// key, so a caller that only ever `read`s it would be handed the first answer
/// for ever — worse than not asking, for a question whose value is being
/// current. It exists for [SessionLauncher.setModel], which must never type a
/// slash command into an agent that is mid-turn. [AgentActivityStatus.unknown]
/// means the registry has never seen this session, and callers must read that
/// as "not safe to type into", never as "probably idle".
final sessionActivityLookupProvider =
    Provider<AgentActivityStatus Function(String sessionId)>(
      (ref) =>
          (sessionId) =>
              ref.read(sessionStatusLookupProvider)(sessionId)?.status ??
              AgentActivityStatus.unknown,
    );

/// **One session's whole status report, read synchronously**, for the callers
/// that need more of it than the status word — the same shape and reasons as
/// [sessionActivityLookupProvider], and the read that one is now expressed in
/// terms of. It exists for `session_send`, which must not type into a session
/// holding an open approval prompt: the keystrokes go into the modal. Null
/// means the registry has never seen the session — *unknown*, not either state.
final sessionStatusLookupProvider =
    Provider<AgentStatusReport? Function(String sessionId)>(
      (ref) => (sessionId) =>
          ref.read(sessionStatusRegistryProvider).reportForOpenId(sessionId),
    );

/// **One session's status now, and every later change to it** — the signal a
/// wait completes on. A function behind a provider because a wait wants a
/// subscription it opens and closes, not a shared one it might inherit
/// mid-flight. Starts nothing: the registry is already cycling for the badges,
/// which is what lets `session_wait` block without a poll of its own.
final sessionStatusStreamProvider =
    Provider<Stream<AgentStatusReport> Function(String sessionId)>(
      (ref) => (sessionId) =>
          ref.read(sessionStatusRegistryProvider).reportsFor(sessionId),
    );

/// paneId → the session standing in it, for the whole workspace. One shared
/// producer rather than a lookup per chip: a family keyed by pane would run one
/// indexed query per drawn chip on every placement change.
///
/// Watched on **placement alone** — the concern that names where a row lives,
/// and it is carried by every change that could move this map. A rename, the
/// most frequent session change in the app, is not on the list and so never
/// wakes a tab.
final placedSessionIdsProvider = Provider<Map<String, String>>((ref) {
  ref.watchSessionKinds(const {SessionChangeKind.placement});
  return ref.read(sessionDaoProvider).paneSessionIds();
});

/// The panes on screen in the terminal right now. Pane ids, not session ids:
/// resolving them costs a scan of the sessions table, and the attention inbox —
/// the only caller — has nothing to retire while it holds no items. Selected as
/// a joined string rather than a `Set`, which compares by identity and would
/// rebuild on every publish the controller makes.
final foregroundTerminalPaneIdsProvider = Provider<List<String>>((ref) {
  // Asked through `exists`, never built: building the terminal controller
  // starts the scrollback autosave timer, which every container that merely
  // reads the inbox would then inherit as a pending timer.
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

/// **What the agent in pane [paneId] is doing**, or null when that is not a
/// question about this pane: no process, a plain shell, or a pane whose row has
/// gone — a tab chip draws [TabLivenessDot] instead, so the two never appear at
/// once. [AgentActivityStatus.unknown] is a real answer here and is drawn as
/// one.
///
/// The session id comes from the **row**, not from the pane's `agentLaunch`: a
/// hand-started `claude` in an ordinary shell pane has no `AgentPaneLaunch` at
/// all, and `SessionAdoptionService` binds it by writing the pane id onto a
/// row.
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
/// the user has to do about it** — not `AgentGridRules`' order, which answers
/// "which matcher describes this agent". A session holding the user up outranks
/// one that has already stopped. Null when no pane in the group has an agent.
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

/// The bottom rows of the pane [session] runs in, or nothing. Empty — rather
/// than absent — for a session with no live pane, so the status service is not
/// handed a stale screen from a process that has exited. [agentId] chooses the
/// depth from `AgentGridRules.scanLines`: these rows are also what is quoted
/// back to the user as "what is being approved", and too few cuts the question
/// off mid-sentence.
List<String> sessionTerminalTail(Ref ref, Session session, {String? agentId}) {
  return sessionTerminalTailForPane(ref, session.paneId, agentId: agentId);
}

/// The bottom rows of [paneId], or nothing when it is absent or no longer live.
/// The row-free form the status registry uses: its loader already carries the
/// pane id, so querying the row again on every cycle is duplicate work.
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
