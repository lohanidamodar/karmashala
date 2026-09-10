/// The approval path, both halves: one rule — a key may be offered, and
/// pressed, only for a wait a status source identified as an approval.
library;

import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import '../../sessions/application/session_launcher.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_status_providers.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/host.dart';

/// The evidence lookup, stubbed in tests because the real one reads
/// `agentSessionStatusProvider` — a terminal grid and the CLI store on disk.
final remoteApprovalEvidenceProvider =
    Provider<Future<AgentStatusReport?> Function(String sessionId)>((ref) {
      return (sessionId) async {
        try {
          return await ref.read(agentSessionStatusProvider(sessionId).future);
        } on Object {
          return null;
        }
      };
    });

/// The answer path: the key comes from [AgentApprovalRules] and is pressed by
/// [SessionLauncher.answerPrompt] — nothing here invents a binding.
Future<String> answerRemoteApproval(
  Ref ref,
  String sessionId,
  String decision,
) async {
  final session = ref.read(sessionDaoProvider).getById(sessionId);
  if (session == null) {
    throw const RemoteApiRefusal(ErrorCode.notFound, 'no such session');
  }
  final agentId = ref
      .read(agentInstallationDaoProvider)
      .getById(session.agentInstallationId)
      ?.agentId;
  final rules = agentId == null
      ? const AgentApprovalRules()
      : ref.read(agentRegistryProvider).byId(agentId)?.approval ??
            const AgentApprovalRules();
  final key = decision == 'approve' ? rules.approve : rules.deny;
  if (key == null) {
    throw RemoteApiRefusal(
      ErrorCode.badRequest,
      'this agent names no way to $decision from outside its terminal',
    );
  }
  // Enforced where the key is pressed: a phone holding a stale card must not
  // type Enter into a session that has merely finished its turn.
  if (!_hasOpenPrompt(await ref.read(remoteApprovalEvidenceProvider)(sessionId))) {
    throw const RemoteApiRefusal(
      ErrorCode.badRequest,
      'this session has no prompt open to answer',
    );
  }
  if (!ref.read(sessionLauncherProvider).answerPrompt(sessionId, key.keys)) {
    throw const RemoteApiRefusal(
      ErrorCode.notFound,
      'this session has no live terminal to answer in',
    );
  }
  return key.label;
}

Future<RemoteApprovalRequest> remoteApprovalEvidenceFor(
  Ref ref,
  String sessionId,
) async {
  final session = ref.read(sessionDaoProvider).getById(sessionId);
  final agentId = session == null
      ? null
      : ref
            .read(agentInstallationDaoProvider)
            .getById(session.agentInstallationId)
            ?.agentId;
  final rules = agentId == null
      ? null
      : ref.read(agentRegistryProvider).byId(agentId)?.approval;
  final report = await ref.read(remoteApprovalEvidenceProvider)(sessionId);
  final asking = report?.status == AgentActivityStatus.awaitingApproval;
  final answerable = _hasOpenPrompt(report);
  return RemoteApprovalRequest(
    sessionId: sessionId,
    evidence: asking ? report!.evidence : const [],
    waiting: asking ? _wireWait(report!.waiting) : RemoteWaitKind.unrecorded,
    // Keys only for a prompt a source could see: `awaitingApproval` is also
    // true of an agent at its own input, where approve would type Enter.
    approveLabel: answerable ? rules?.approve?.label : null,
    denyLabel: answerable ? rules?.deny?.label : null,
  );
}

/// The one rule both halves turn on, kept on [AgentStatusReport.hasOpenPrompt]
/// because `session_send` refuses on it too. Absent is not an open prompt.
bool _hasOpenPrompt(AgentStatusReport? report) => report?.hasOpenPrompt ?? false;

RemoteWaitKind _wireWait(AgentWaitKind kind) => switch (kind) {
  AgentWaitKind.approval => RemoteWaitKind.approval,
  AgentWaitKind.input => RemoteWaitKind.input,
  AgentWaitKind.unrecorded => RemoteWaitKind.unrecorded,
};
