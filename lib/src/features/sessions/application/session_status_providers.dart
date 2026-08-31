import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/application/agent_providers.dart';
import '../../agents/domain/agent_status.dart';
import '../../notifications/application/notification_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../../terminal/data/terminal_grid_text.dart';
import '../domain/session.dart';

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
  final paneId = session.paneId;
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
