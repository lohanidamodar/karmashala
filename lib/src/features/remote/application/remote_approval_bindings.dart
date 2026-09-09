/// The Loop-49 approval path, both halves of it: the evidence a phone is shown
/// and the key it presses.
///
/// One family because it is one rule — a key may be offered, and pressed,
/// only for a wait a status source identified as an approval — and three
/// copies of that rule could disagree.
library;

import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import '../../agents/domain/agent_status.dart';
import '../../sessions/application/session_launcher.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_status_providers.dart';
import '../domain/remote_payloads.dart';
import '../protocol.dart';
import 'host_bindings.dart';

/// The Loop-49 evidence lookup, stubbed in tests for the same reason: the
/// real one reads `agentSessionStatusProvider`, whose sources include a
/// terminal grid and the CLI store on disk.
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

/// The Loop-49 answer path: the key comes from the agent's own
/// [AgentApprovalRules] and is pressed by [SessionLauncher.answerPrompt] —
/// nothing here invents a binding.
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
  // The desktop card's rule, enforced where the key is actually pressed: a
  // phone holding a stale card — or an older build that was handed labels it
  // should not have been — must not type Enter into a session that has merely
  // finished its turn.
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
    // Keys only for a prompt a source could actually see. `awaitingApproval`
    // alone says the session stopped for the user, which is also true of an
    // agent sitting at its own input — and approve types Enter there.
    approveLabel: answerable ? rules?.approve?.label : null,
    denyLabel: answerable ? rules?.deny?.label : null,
  );
}

/// The one rule both halves of the remote approval path turn on, and the same
/// one `ApprovalRequestCard` draws its buttons from: a key may be offered, and
/// pressed, only for a wait a status source identified as an approval.
///
/// The rule itself lives on [AgentStatusReport.hasOpenPrompt], because
/// `session_send` refuses on it too and three copies of it could disagree.
/// Absent is not an open prompt: a session no source could read is our blind
/// spot, not a modal.
bool _hasOpenPrompt(AgentStatusReport? report) => report?.hasOpenPrompt ?? false;

RemoteWaitKind _wireWait(AgentWaitKind kind) => switch (kind) {
  AgentWaitKind.approval => RemoteWaitKind.approval,
  AgentWaitKind.input => RemoteWaitKind.input,
  AgentWaitKind.unrecorded => RemoteWaitKind.unrecorded,
};
