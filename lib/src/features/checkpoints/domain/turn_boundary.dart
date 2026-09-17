import 'package:agent_cli/descriptors.dart';

/// Which edge of a turn a status move is.
enum TurnEdge { started, ended }

/// Reads turn edges off one session's status moves, from any source: a hook's
/// `UserPromptSubmit`/`Stop` and a grid or transcript reading all land here as
/// a status. `unknown` and approvals move nothing, so a hook that aged out
/// mid-turn or a permission prompt cannot end a turn early.
class TurnBoundaryTracker {
  final Map<String, bool> _inTurn = {};

  TurnEdge? observe(String sessionId, AgentActivityStatus status) {
    final inTurn = _inTurn[sessionId] ?? false;
    switch (status) {
      case AgentActivityStatus.working:
        if (inTurn) return null;
        _inTurn[sessionId] = true;
        return TurnEdge.started;
      case AgentActivityStatus.idle:
      case AgentActivityStatus.failed:
        if (!inTurn) return null;
        _inTurn[sessionId] = false;
        return TurnEdge.ended;
      case AgentActivityStatus.awaitingApproval:
      case AgentActivityStatus.unknown:
        return null;
    }
  }

  bool inTurn(String sessionId) => _inTurn[sessionId] ?? false;

  void forget(String sessionId) => _inTurn.remove(sessionId);
}
