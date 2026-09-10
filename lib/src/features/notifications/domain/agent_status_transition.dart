import 'package:agent_cli/descriptors.dart';
import 'agent_session_key.dart';

/// One observed change in an agent session's status. [from] is `null` on a
/// first observation, which the policy treats as no evidence rather than news.
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

  /// Where the *new* status came from. Only [AgentStatusSource.hook] proves it
  /// happened now; a polled state file may have looked like this for hours.
  final AgentStatusSource source;

  /// What the agent is waiting *on*, when the source could tell.
  /// `awaitingApproval` says the user is held up, not that there is a button.
  final AgentWaitKind waiting;

  @override
  String toString() =>
      'AgentStatusTransition($session, ${from?.name} -> ${to.name}, '
      '${source.name})';
}
