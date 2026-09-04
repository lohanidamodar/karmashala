import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/application/agent_providers.dart';
import '../../agents/domain/agent_status.dart';
import '../../notifications/application/notification_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../../terminal/data/terminal_grid_text.dart';
import '../domain/session.dart';
import 'session_providers.dart';
import 'session_signals.dart';

/// What one session's agent is doing.
///
/// A **projection**, and nothing more. Until Loop 87 this was a per-session
/// polling loop: every rendered `AgentStatusBadge` started its own 1.2-second
/// `while (true)`, re-read the session row, read the terminal tail, called the
/// status service — which could tail a transcript from disk — and, until the
/// transcript was found, kicked off a full CLI-store discovery scan of its own
/// every ten seconds. The Explorer puts a badge on every visible session card,
/// so a hundred rows meant roughly eighty-three polls a second and up to ten
/// store scans a second, and expanding a project changed how much work the app
/// did. Status cost was a side effect of layout.
///
/// Now it selects a cached entry from `SessionStatusRegistry` and starts
/// nothing: no timer, no filesystem access, no store scan. A hundred badges are
/// a hundred subscriptions to one broadcast signal that fires only when a
/// session's evidence actually changes.
///
/// Still keyed by the **workspace row id**, and still a `StreamProvider`, so
/// every consumer and every test override reads exactly as it did.
///
/// Resolves to [AgentActivityStatus.unknown] for a session with no pane and no
/// hook — an imported session, one launched into somebody else's terminal, or
/// an agent nobody has taught us to read. That is a first-class answer, not a
/// failure, and it is delivered immediately rather than after a first poll.
final agentSessionStatusProvider = StreamProvider.autoDispose
    .family<AgentStatusReport, String>(
      (ref, sessionId) =>
          ref.watch(sessionStatusRegistryProvider).reportsFor(sessionId),
    );

/// **One session's status, read synchronously, for a decision being made now.**
///
/// A function behind a provider rather than a `family`, and the shape is the
/// point. A `Provider.family` caches per key, so a caller that only ever
/// `read`s it would go on being handed the first answer forever — which for a
/// question whose whole value is that it is current is worse than not asking.
/// A function is computed at the moment of the call and cached nowhere.
///
/// It exists for [SessionLauncher.setModel], which must never type a slash
/// command into an agent that is mid-turn, and it is a provider rather than a
/// direct registry read so a test can put a session into a state without
/// standing up the status pipeline that produces one.
///
/// Answers [AgentActivityStatus.unknown] for a session the registry has never
/// seen — an imported row, one in somebody else's terminal, an agent nobody has
/// taught us to read — and callers must treat that as "not safe to type into",
/// never as "probably idle".
final sessionActivityLookupProvider =
    Provider<AgentActivityStatus Function(String sessionId)>(
      (ref) =>
          (sessionId) =>
              ref.read(sessionStatusLookupProvider)(sessionId)?.status ??
              AgentActivityStatus.unknown,
    );

/// **One session's whole status report, read synchronously**, for the callers
/// that need more of it than the status word.
///
/// The same shape and the same reasons as [sessionActivityLookupProvider] — a
/// function computed at the call rather than a `family` that would cache the
/// first answer to a question whose only value is being current — and the read
/// that one is now expressed in terms of, so the two cannot disagree about what
/// the registry says.
///
/// It exists for `session_send`, which must not type a message into a session
/// holding an open approval prompt: the keystrokes go into the modal, and
/// [AgentStatusReport.hasOpenPrompt] needs [AgentStatusReport.waiting] as well
/// as the status.
///
/// Null for a session the registry has never seen — an imported row, one in
/// somebody else's terminal, an agent nobody has taught us to read. That is
/// *unknown*, and callers must not read it as either state.
final sessionStatusLookupProvider =
    Provider<AgentStatusReport? Function(String sessionId)>(
      (ref) => (sessionId) =>
          ref.read(sessionStatusRegistryProvider).reportForOpenId(sessionId),
    );

/// paneId → the session standing in it, for the whole workspace.
///
/// One shared producer rather than a lookup per chip. Both tab strips draw one
/// chip per tab or per pane and each of them wants this answer, so a family
/// keyed by pane would run one indexed query per drawn chip on every placement
/// change; this runs [SessionDao.paneSessionIds] once and every chip reads its
/// own key out of the map with a `select`.
///
/// Watched on **placement alone**. That is the concern that names where a row
/// lives, and it is carried by every change that could move this map:
/// `SessionChange.created` and `.removed` both include it, and so does the
/// `.moved` adoption publishes when it binds or releases a pane. A rename — the
/// most frequent session change in the app, published on the CLI store sweep's
/// own timer — is not on the list and therefore never wakes a tab.
final placedSessionIdsProvider = Provider<Map<String, String>>((ref) {
  ref.watchSessionKinds(const {SessionChangeKind.placement});
  return ref.read(sessionDaoProvider).paneSessionIds();
});

/// The panes on screen in the terminal right now.
///
/// Pane ids, not session ids, and deliberately: resolving them costs a scan of
/// the sessions table, and the attention inbox — the only caller — has nothing
/// to retire while it holds no items. `session_start_cost_test` counts that
/// scan and fails if a start pays for it.
///
/// The visible panes are selected as a joined string rather than a set: a
/// `Set` compares by identity, so selecting one would rebuild on every publish
/// the controller makes, which is the cost the tab strip's own providers exist
/// to avoid.
final foregroundTerminalPaneIdsProvider = Provider<List<String>>((ref) {
  // Asked through `exists`, never built: the inbox must not be the thing that
  // constructs the terminal controller. Building it starts the scrollback
  // autosave timer, which is why every container that merely reads the inbox
  // would otherwise inherit a pending timer.
  if (!ref.exists(terminalSessionsControllerProvider)) return const [];
  if (!ref.watch(terminalVisibleProvider)) return const [];
  final joined = ref.watch(
    terminalSessionsControllerProvider.select(
      (state) => state.activeTab?.layout.visiblePanes.join('\u0000') ?? '',
    ),
  );
  return joined.isEmpty ? const [] : joined.split('\u0000');
});

/// **What the agent in pane [paneId] is doing**, or null when that is not a
/// question about this pane.
///
/// Null in three cases, and they are one case: there is no agent to report on.
/// A pane with no process (a shell that exited, restored history), a plain
/// shell, and a pane whose row has gone. A tab chip draws its liveness marker
/// instead — [TabLivenessDot] — so the two never appear at once and the strip
/// never shows a status read off a screen nothing is writing to.
///
/// [AgentActivityStatus.unknown] is a real answer here and is drawn as one: a
/// live agent pane whose status no source can read is different from a shell
/// tab, and collapsing them would make the marker's absence mean two things.
///
/// The session id comes from the **row**, not from the pane's `agentLaunch`,
/// and that is the whole reason this reaches the sessions the owner asked
/// about: a hand-started `claude` in an ordinary shell pane has no
/// `AgentPaneLaunch` at all, and `SessionAdoptionService` binds it by writing
/// the pane id onto a row.
///
/// Costs nothing per tick. `agentSessionStatusProvider` is a projection of the
/// one registry the whole app shares — no timer, no disk, no store scan — and
/// the `select` here narrows it to the status word, so a cycle that reconfirms
/// what a pane was already doing rebuilds nothing.
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

/// The one status a chip standing for several panes shows.
///
/// Ordered by **what the user has to do about it**, which is not the order
/// `AgentGridRules` reads a single screen in. There the question is "which of
/// these matchers describes this agent", and a failure wins because an error
/// printed under a spinner is the newer fact. Here the question is "which of
/// these panes should this one glyph be about", and a session holding the user
/// up outranks one that has already stopped: the first still wants something,
/// the second is waiting to be read.
///
/// Null when no pane in the group has an agent, which is what a tab of plain
/// shells is.
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

/// The bottom rows of the pane [session] runs in, or nothing.
///
/// Empty — rather than absent — for a session with no live pane, so the status
/// service's grid source is simply not consulted rather than being handed a
/// stale screen from a process that has exited.
///
/// [agentId] chooses the depth: `AgentGridRules.scanLines` is the descriptor's
/// own statement of how far up its prompt reaches, and this used to ignore it
/// and take the 12-row default for every agent — so the field was live in the
/// tests and dead in the app. It matters more now than it did for status alone,
/// because these rows are also what gets quoted back to the user as "what is
/// being approved": too few and the question is cut off mid-sentence.
List<String> sessionTerminalTail(Ref ref, Session session, {String? agentId}) {
  return sessionTerminalTailForPane(ref, session.paneId, agentId: agentId);
}

/// The bottom rows of [paneId], or nothing when it is absent or no longer live.
///
/// This is the row-free form used by the status registry. Its loader has
/// already read the session row and carries the pane id in `WatchedSession`, so
/// querying the row again for every watched session on every cycle is pure
/// duplicate work.
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
