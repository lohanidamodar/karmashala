import 'package:karmashala_core/util.dart';
import 'package:agent_cli/descriptors.dart';
import 'agent_hook_receiver.dart';
import 'agent_state_file_status_source.dart';
import 'terminal_grid_status_source.dart';

/// Answers "what is this agent session doing?": a fresh hook, then the grid but
/// only for `awaitingApproval`/`failed`, then the state file, then the grid.
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
  /// believe. An in-memory lookup, so it is free to ask on every cycle.
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

  /// Whether the transcript still has to be read once [hook] and [grid] are
  /// known — asked separately, because it is the one expensive question.
  bool needsStateFile(AgentStatusReport? hook, AgentStatusReport? grid) =>
      hook == null && !(grid != null && escalates(grid));

  /// The precedence itself, with every source already gathered. Does no I/O, so
  /// a cached [state] can be recomposed as often as it likes.
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
