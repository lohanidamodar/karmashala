import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import 'session_providers.dart';
import 'session_signals.dart';

/// **Whether [sessionId]'s agent is spoken to over ACP**: its installation's
/// agent passes [agentSpeaksAcp]. Such a session has no terminal of ours — the server owns
/// the process — and its conversation is the server's own rows.
final isAcpSessionProvider = Provider.autoDispose.family<bool, String>((
  ref,
  sessionId,
) {
  // The row appearing or going is `membership`; a switch in place moves its
  // installation, told as `placement`.
  ref.watchSessionKinds(const {
    SessionChangeKind.membership,
    SessionChangeKind.placement,
  });
  final row = ref.read(sessionsDataProvider).getById(sessionId);
  if (row == null) return false;
  final installations = ref.watch(agentInstallationsDataProvider);
  // The installation can arrive after the row on a fresh connection.
  final arrivals = installations.changes.listen((_) => ref.invalidateSelf());
  ref.onDispose(arrivals.cancel);
  ref.watch(agentRegistryProvider);
  return installationSpeaksAcp(ref, row.agentInstallationId);
});

/// The rule behind [isAcpSessionProvider], for a row in hand — a launch's
/// result — that the feed may not have delivered yet. Read once, not watched.
bool installationSpeaksAcp(Ref ref, String installationId) {
  final agentId = ref
      .read(agentInstallationsDataProvider)
      .getById(installationId)
      ?.agentId;
  if (agentId == null) return false;
  return agentSpeaksAcp(ref.read(agentRegistryProvider), agentId);
}
