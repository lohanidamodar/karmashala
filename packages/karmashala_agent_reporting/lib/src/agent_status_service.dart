import 'package:karmashala_core/util.dart';
import 'package:agent_cli/descriptors.dart';
import 'agent_hook_receiver.dart';
import 'agent_state_file_status_source.dart';
import 'terminal_grid_status_source.dart';

/// Answers "what is this agent session doing?": a fresh hook, then the grid but
/// only for `awaitingApproval`/`failed`, then the state file, then the grid.
///
/// One exception to the hook's rank: a hook saying the turn ended (`idle`)
/// yields to a screen showing a prompt, because an agent can draw a menu after
/// its turn with no hook of its own — Claude Code's startup offers do — and
/// the idle hook is then older than the menu. The caller hands in a grid read
/// after the hook, or none.
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
    final grid = gridReport(query, now);
    if (hook != null) {
      return compose(query: query, now: now, hook: hook, grid: grid);
    }
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
    // Work in flight fires nothing while it runs: a background shell is silent
    // until it ends, and the hook that ends it is what retires this one.
    if (hook.status == AgentActivityStatus.working &&
        hook.inFlight.isNotEmpty) {
      return hook;
    }
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

  /// Whether [grid] shows a prompt the agent drew after [hook] — the one case
  /// a screen outranks a fresh hook: after the turn ended, or, when the
  /// screen is known to be read since the hook ([screenAfterHook]), while it
  /// runs, as a second prompt in one turn fires no hook of its own.
  static bool promptAfter(
    AgentStatusReport hook,
    AgentStatusReport? grid, {
    bool screenAfterHook = false,
  }) =>
      (hook.status == AgentActivityStatus.idle ||
          (screenAfterHook && hook.status == AgentActivityStatus.working)) &&
      grid != null &&
      grid.status == AgentActivityStatus.awaitingApproval;

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
    bool screenAfterHook = false,
  }) {
    if (hook != null) {
      return promptAfter(hook, grid, screenAfterHook: screenAfterHook)
          ? grid!
          : hook;
    }
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
