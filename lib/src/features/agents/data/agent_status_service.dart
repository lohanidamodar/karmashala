import 'package:karmashala_core/util.dart';
import 'package:agent_cli/descriptors.dart';
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
    if (descriptor == null) return unknownFor(query, now);

    final hook = hookReport(query, now);
    if (hook != null) return hook;

    final grid = gridReport(query, now);
    if (grid != null && escalates(grid)) return grid;

    final path = query.stateFilePath;
    final state = path == null
        ? null
        : await stateFileSource.read(
            descriptor,
            path,
            now,
            sessionId: query.sessionId,
          );

    return compose(query: query, now: now, grid: grid, state: state);
  }

  /// The hook's answer for [query], when one exists and is fresh enough to
  /// believe. An in-memory map lookup, and therefore free to ask about every
  /// known session on every cycle.
  AgentStatusReport? hookReport(AgentStatusQuery query, DateTime now) {
    final hook = hookReports.latest(query.agentId, query.sessionId);
    if (hook == null) return null;
    return now.difference(hook.observedAt) <= hookFreshness ? hook : null;
  }

  /// What [query]'s already-captured screen says, or `null`. In memory: the
  /// rows were read off a live terminal by the caller.
  AgentStatusReport? gridReport(AgentStatusQuery query, DateTime now) {
    if (query.terminalTailLines.isEmpty) return null;
    final descriptor = registry.byId(query.agentId);
    if (descriptor == null) return null;
    return gridSource.read(
      descriptor,
      query.terminalTailLines,
      now,
      sessionId: query.sessionId,
    );
  }

  /// Whether a grid reading is allowed to outrank the transcript — step 2 of
  /// the precedence above.
  static bool escalates(AgentStatusReport grid) =>
      grid.status == AgentActivityStatus.awaitingApproval ||
      grid.status == AgentActivityStatus.failed;

  /// Whether the transcript still has to be consulted once [hook] and [grid]
  /// are known. The one expensive question in the precedence, asked separately
  /// so a scheduler can decide whether this session is worth a disk read at all.
  bool needsStateFile(AgentStatusReport? hook, AgentStatusReport? grid) =>
      hook == null && !(grid != null && escalates(grid));

  /// The precedence itself, with every source already gathered. Does no I/O, so
  /// a registry holding a cached [state] report can recompute a session's status
  /// as often as it likes.
  AgentStatusReport compose({
    required AgentStatusQuery query,
    required DateTime now,
    AgentStatusReport? hook,
    AgentStatusReport? grid,
    AgentStatusReport? state,
  }) {
    if (hook != null) return hook;
    if (grid != null && escalates(grid)) return grid;
    if (state != null) return state;
    if (grid != null) return grid;
    return unknownFor(query, now);
  }

  AgentStatusReport unknownFor(AgentStatusQuery query, DateTime now) =>
      AgentStatusReport(
        agentId: query.agentId,
        sessionId: query.sessionId,
        status: AgentActivityStatus.unknown,
        source: AgentStatusSource.none,
        observedAt: now,
      );
}
