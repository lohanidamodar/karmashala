import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/application/agent_status_providers.dart';
import '../../agents/domain/agent_status.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../../terminal/data/terminal_grid_text.dart';
import '../domain/session.dart';
import 'session_chat_source.dart';
import 'session_providers.dart';

/// How often a PTY-hosted session's screen is re-read for status.
///
/// Deliberately slow. This is a status badge, not an animation: a second of lag
/// on "the agent finished" costs nothing, and the alternative — recomputing on
/// every buffer notification — would run on every frame of a busy agent's
/// output, which is exactly the cost Loop 26 spent a whole loop removing.
const Duration kAgentStatusPollInterval = Duration(milliseconds: 1200);

/// What one session's agent is doing, refreshed while the session is on screen.
///
/// Reads whichever of the three sources apply, in `AgentStatusService`'s order.
/// The one this loop adds is the pane's own screen, which is why this lives with
/// the sessions feature rather than beside the other two: only a session knows
/// which pane it is in.
///
/// Resolves to [AgentActivityStatus.unknown] for a session with no pane and no
/// hook — an imported session, one launched into somebody else's terminal, or an
/// agent nobody has taught us to read. That is a first-class answer, not a
/// failure.
final agentSessionStatusProvider = StreamProvider.autoDispose
    .family<AgentStatusReport, String>((ref, sessionId) async* {
      final session = ref.read(sessionDaoProvider).getById(sessionId);
      if (session == null) return;
      final agentId = ref
          .read(agentInstallationDaoProvider)
          .getById(session.agentInstallationId)
          ?.agentId;
      if (agentId == null) return;

      final service = ref.read(agentStatusServiceProvider);
      final locator = ref.read(sessionTranscriptLocatorProvider);
      final clock = ref.read(clockProvider);
      String? statePath;
      DateTime? nextSearch;

      while (true) {
        // Re-read the row each tick: an agent that would not accept a session id
        // announces one later, and the transcript only becomes findable then.
        final current = ref.read(sessionDaoProvider).getById(sessionId);
        final externalId = current?.externalSessionId;
        final now = clock.nowUtc();

        // Native sessions used to pass no [stateFilePath] at all, so they read
        // `unknown` forever while imported ones — which carry the path from CLI
        // detection — did not. Same store, same file; the only difference was
        // that nobody had looked it up. The search is a full store scan, so it
        // runs on its own slow interval and stops for good once it succeeds.
        if (statePath == null &&
            externalId != null &&
            externalId.isNotEmpty &&
            (nextSearch == null || !now.isBefore(nextSearch))) {
          nextSearch = now.add(kNativeTranscriptSearchInterval);
          statePath = await locator.locate(
            agentId: agentId,
            externalSessionId: externalId,
          );
        }

        yield await service.statusFor(
          AgentStatusQuery(
            agentId: agentId,
            // The CLI's id when we have one — the key hooks and state files
            // share. Falling back to our own id keeps the query well-formed for
            // an agent that never announced one; it simply will not match a hook
            // report, which is the truth.
            sessionId: externalId ?? sessionId,
            stateFilePath: statePath,
            terminalTailLines: sessionTerminalTail(ref, current ?? session),
          ),
        );
        await Future<void>.delayed(kAgentStatusPollInterval);
      }
    });

/// How long between attempts to find a native session's transcript on disk.
///
/// Much slower than the status poll because finding it costs a scan of every
/// CLI store, and because the thing being waited for is the agent writing its
/// first turn — which happens once, seconds-to-minutes after launch, and never
/// again.
const Duration kNativeTranscriptSearchInterval = Duration(seconds: 10);

/// The bottom rows of the pane [session] runs in, or nothing.
///
/// Empty — rather than absent — for a session with no live pane, so the status
/// service's grid source is simply not consulted rather than being handed a
/// stale screen from a process that has exited.
List<String> sessionTerminalTail(Ref ref, Session session) {
  final paneId = session.paneId;
  if (paneId == null) return const [];
  final instance = ref
      .read(terminalSessionsControllerProvider.notifier)
      .instanceFor(paneId);
  if (instance == null || !instance.liveness.value.isLive) return const [];
  return terminalTailLines(instance.terminal);
}
