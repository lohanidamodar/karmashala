part of 'remote_companion_gateway.dart';

// The approval card: raising one when the host asks, and taking it off the
// screen with a reason when it is answered — here or anywhere else.

extension _GatewayApprovals on RemoteCompanionGateway {
  void _applyApproval(RemoteApprovalRequest request) {
    final approval = CompanionApproval(
      id: 'approval-${_nextApprovalId++}',
      sessionId: request.sessionId,
      // The wire carries no agent name, and the phone invents no claim.
      agentName: 'The agent',
      evidence: request.evidence,
      waiting: request.waiting,
      approveLabel: request.approveLabel,
      denyLabel: request.denyLabel,
      question: request.question,
      menu: request.menu,
      options: request.options,
    );
    _approvalOf(request.sessionId).value = approval;
    final summary = _currentSummary(request.sessionId);
    _noteAttention(
      request.sessionId,
      'needs_approval',
      summary?.title ?? request.sessionId,
    );
    _stampAttention(request.sessionId, CompanionAttentionKind.needsYou);
  }

  /// Takes a card off the screen and says why. The nothing-to-do case is
  /// deliberately silent: a `session.changed` for a session that was never
  /// asking must not announce a resolution the reader never saw a request for.
  void _retireApproval(String sessionId, CompanionApprovalOutcome outcome) {
    final pending = _approvalOf(sessionId);
    if (pending.value == null) return;
    pending.value = null;
    if (!_approvalResolutions.isClosed) {
      _approvalResolutions.add(
        CompanionApprovalResolution(sessionId: sessionId, outcome: outcome),
      );
    }
  }

  _Watched<CompanionApproval?> _approvalOf(String sessionId) =>
      _approvals[sessionId] ??= _Watched(null);
}
