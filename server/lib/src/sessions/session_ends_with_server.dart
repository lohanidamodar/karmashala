import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_host_protocol/protocol.dart'
    show SessionEndedWithoutCode;
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart'
    show SessionFacts, UnknownResolver;

import '../automations/daemon_agents.dart';

/// What a host's silence means for a row whose agent runs inside this server
/// and ends with it — its installation's adapter speaks ACP, decided by that
/// capability, never by the agent's id. Such a session has no process
/// anybody could still be running out of sight, so its row is never
/// `unknown`: no host holding it at start, or the server's own stop, is a
/// clean end, `completed`; an end with no code and any other reason — a
/// start refused, a login demanded, a hang given up on — is `failed`. Every
/// other row keeps `unknown`.
UnknownResolver sessionEndsWithServer({
  required CheckoutRows rows,
  required DaemonAgents agents,
}) => (Session session, SessionFacts? facts) {
  if (!_speaksAcp(rows, agents, session)) return SessionStatus.unknown;
  if (facts == null || facts.reason == SessionEndedWithoutCode.hostStopped) {
    return SessionStatus.completed;
  }
  return SessionStatus.failed;
};

/// Whether row [String]'s agent is one this server speaks to over ACP — by
/// the same capability — so any client's message to it while nothing runs
/// it resumes it here first. False for a row that is gone.
bool Function(String sessionId) sessionSpeaksAcp({
  required CheckoutRows rows,
  required DaemonAgents agents,
  required Session? Function(String sessionId) sessionOf,
}) => (sessionId) {
  final session = sessionOf(sessionId);
  return session != null && _speaksAcp(rows, agents, session);
};

bool _speaksAcp(CheckoutRows rows, DaemonAgents agents, Session session) {
  final agentId = rows.installation(session.agentInstallationId)?.agentId;
  return agentId != null && agents.adapterOf(agentId)?.acp != null;
}
