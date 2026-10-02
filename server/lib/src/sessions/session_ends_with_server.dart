import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_session/session.dart';

import '../automations/daemon_agents.dart';

/// Whether a row's agent runs inside this server and ends with it: its
/// installation's adapter speaks ACP, so the server owns the process outright
/// — no terminal of it to lose sight of, nothing of it a restart could adopt.
/// Decided by the adapter's capability, never by the agent's id.
bool Function(Session session) sessionEndsWithServer({
  required CheckoutRows rows,
  required DaemonAgents agents,
}) => (session) {
  final agentId = rows.installation(session.agentInstallationId)?.agentId;
  return agentId != null && agents.adapterOf(agentId)?.acp != null;
};
