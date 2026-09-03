import '../../agents/domain/agent_status.dart';
import 'agent_session_key.dart';

/// One observed change in an agent session's status.
///
/// [from] is `null` on the first observation of a session — which happens for
/// every live session on app start, and is why the policy treats it as "no
/// evidence anything just changed" rather than as news.
class AgentStatusTransition {
  const AgentStatusTransition({
    required this.session,
    required this.from,
    required this.to,
    required this.source,
    this.waiting = AgentWaitKind.unrecorded,
  });

  final AgentSessionKey session;

  /// The previously observed status, or `null` if this session had not been
  /// observed before.
  final AgentActivityStatus? from;

  final AgentActivityStatus to;

  /// Where the *new* status came from. Only [AgentStatusSource.hook] is
  /// first-hand evidence that the change happened just now: the agent called
  /// us. A state file is something we polled, and it may have been sitting in
  /// its current shape for hours.
  final AgentStatusSource source;

  /// What the agent is waiting *on*, when the source could tell.
  ///
  /// [AgentActivityStatus.awaitingApproval] answers "is the user being held
  /// up", which is deliberately true for Claude Code's 60-second idle nudge as
  /// well as for a permission prompt. It does not answer "is there something to
  /// approve", and a surface that says there is when there is not sends the
  /// user to look for a button that was never drawn. That is the difference
  /// this carries.
  final AgentWaitKind waiting;

  @override
  String toString() =>
      'AgentStatusTransition($session, ${from?.name} -> ${to.name}, '
      '${source.name})';
}
