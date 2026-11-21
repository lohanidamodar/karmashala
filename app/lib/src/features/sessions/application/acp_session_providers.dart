import 'package:agent_cli/descriptors.dart' show AcpLaunchSpec;
import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import 'session_agent_providers.dart';

/// **Whether [sessionId]'s agent is spoken to over ACP**: its installation's
/// agent passes [agentSpeaksAcp]. Such a session has no terminal of ours — the server owns
/// the process — and its conversation is the server's own rows.
final isAcpSessionProvider = Provider.autoDispose.family<bool, String>((
  ref,
  sessionId,
) {
  final agentId = ref.watch(sessionAgentIdProvider(sessionId));
  return agentId != null &&
      agentSpeaksAcp(ref.watch(agentRegistryProvider), agentId);
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

/// How [sessionId]'s ACP agent is driven — where its modes are placed on
/// rungs — or null for a session that is not ACP or not yet known.
final sessionAcpSpecProvider = Provider.autoDispose
    .family<AcpLaunchSpec?, String>((ref, sessionId) {
      final agentId = ref.watch(sessionAgentIdProvider(sessionId));
      if (agentId == null) return null;
      return ref.watch(agentRegistryProvider).adapterFor(agentId)?.acp;
    });
