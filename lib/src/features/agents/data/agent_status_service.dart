import '../../../core/util/clock.dart';
import '../domain/agent_registry.dart';
import '../domain/agent_status.dart';
import 'agent_hook_receiver.dart';
import 'agent_state_file_status_source.dart';

/// Answers "what is this agent session doing?" from the sources we have.
///
/// Precedence: a recent hook callback, then the agent's own state file, then
/// [AgentActivityStatus.unknown]. Only hooks can observe `awaitingApproval` and
/// `failed` — neither CLI writes those to its transcript in a form we can trust
/// — so an agent without installed hooks legitimately reports less.
class AgentStatusService {
  AgentStatusService({
    required this.registry,
    required this.hookReports,
    required this.clock,
    this.stateFileSource = const AgentStateFileStatusSource(),
    this.hookFreshness = const Duration(minutes: 5),
  });

  final AgentRegistry registry;
  final AgentHookReports hookReports;
  final Clock clock;
  final AgentStateFileStatusSource stateFileSource;

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
