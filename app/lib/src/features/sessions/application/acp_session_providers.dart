import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import 'session_providers.dart';
import 'session_signals.dart';

/// **Whether [sessionId]'s agent is spoken to over ACP** (ACP design, C5):
/// its installation's adapter declares `acp`. Asked of the adapter, never of
/// the agent's id. Such a session has no terminal of ours — the server owns
/// the process — and its conversation is the server's own rows.
final isAcpSessionProvider = Provider.autoDispose.family<bool, String>((
  ref,
  sessionId,
) {
  // The row appearing or going is `membership`; which installation it runs
  // under never changes after that.
  ref.watchSessionKinds(const {SessionChangeKind.membership});
  final row = ref.read(sessionsDataProvider).getById(sessionId);
  if (row == null) return false;
  final installations = ref.watch(agentInstallationsDataProvider);
  // The installation can arrive after the row on a fresh connection.
  final arrivals = installations.changes.listen((_) => ref.invalidateSelf());
  ref.onDispose(arrivals.cancel);
  final agentId = installations.getById(row.agentInstallationId)?.agentId;
  if (agentId == null) return false;
  return ref.watch(agentRegistryProvider).adapterFor(agentId)?.acp != null;
});
