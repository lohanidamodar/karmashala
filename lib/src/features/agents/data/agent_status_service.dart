import '../../../core/util/clock.dart';
import '../domain/agent_registry.dart';
import '../domain/agent_status.dart';
import 'agent_hook_receiver.dart';
import 'agent_state_file_status_source.dart';
import 'terminal_grid_status_source.dart';

/// Answers "what is this agent session doing?" from the sources we have.
///
/// Precedence:
///
/// 1. a hook callback newer than [hookFreshness];
/// 2. the terminal grid, **but only when it says `awaitingApproval` or
///    `failed`**;
/// 3. the agent's own state file;
/// 4. the terminal grid for anything else;
/// 5. [AgentActivityStatus.unknown].
///
/// Step 2 is the one that needs explaining. A transcript structurally cannot
/// express "a modal is on screen waiting for you" — that is why Loop 28 made
/// those two states hook-only — but a screen can, because the prompt is drawn on
/// it. So the grid is allowed to *escalate* to a state no other source but a
/// hook could have produced, and is otherwise the last resort it was introduced
/// as. Without that split, an agent sitting on an approval dialog would report
/// `working` from a transcript that stopped mid-turn, which is worse than
/// `unknown` and much worse than the truth.
class AgentStatusService {
  AgentStatusService({
    required this.registry,
    required this.hookReports,
    required this.clock,
    this.stateFileSource = const AgentStateFileStatusSource(),
    this.gridSource = const TerminalGridStatusSource(),
    this.hookFreshness = const Duration(minutes: 5),
  });

  final AgentRegistry registry;
  final AgentHookReports hookReports;
  final Clock clock;
  final AgentStateFileStatusSource stateFileSource;
  final TerminalGridStatusSource gridSource;

  /// How old a hook report may be before it stops being believed. The app may
  /// have restarted, or the agent may have exited without a closing hook.
  final Duration hookFreshness;

  Future<AgentStatusReport> statusFor(AgentStatusQuery query) async {
    final now = clock.nowUtc();
    final descriptor = registry.byId(query.agentId);
    if (descriptor == null) return _unknown(query, now);

    final hook = hookReports.latest(query.agentId, query.sessionId);
    if (hook != null && now.difference(hook.observedAt) <= hookFreshness) {
      return hook;
    }

    final grid = query.terminalTailLines.isEmpty
        ? null
        : gridSource.read(
            descriptor,
            query.terminalTailLines,
            now,
            sessionId: query.sessionId,
          );
    if (grid != null &&
        (grid.status == AgentActivityStatus.awaitingApproval ||
            grid.status == AgentActivityStatus.failed)) {
      return grid;
    }

    final path = query.stateFilePath;
    if (path != null) {
      final report = await stateFileSource.read(
        descriptor,
        path,
        now,
        sessionId: query.sessionId,
      );
      if (report != null) return report;
    }

    if (grid != null) return grid;

    return _unknown(query, now);
  }

  AgentStatusReport _unknown(AgentStatusQuery query, DateTime now) =>
      AgentStatusReport(
        agentId: query.agentId,
        sessionId: query.sessionId,
        status: AgentActivityStatus.unknown,
        source: AgentStatusSource.none,
        observedAt: now,
      );
}
