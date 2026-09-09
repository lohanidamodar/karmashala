import 'package:riverpod/riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../domain/decision_record.dart';
import 'session_decision_providers.dart';
import 'session_providers.dart';

/// The only way anything writes to a session's decision record.
///
/// One method per **explicit act**, named after the act, so that reading this
/// class is reading the complete list of things that can put a row in the
/// record. That is the property the record is worth having for: an agent
/// reading a handoff packet has no way to check a decision, so every row has
/// to be traceable to somebody actually deciding something rather than to a
/// heuristic that ran over a conversation.
///
/// **Nothing here reads prose.** There is no method that takes a transcript, a
/// message, or a terminal buffer. `handoff_packet.dart` argues the case at
/// length for the recap and it applies with more force here: a summariser's
/// errors are invisible to the reader who most needs them, and a decision
/// record that is sometimes invented is worse than none, because the reader
/// cannot tell which row is which.
///
/// Every write is best-effort and returns `null` rather than throwing. A
/// decision that could not be recorded must never break the act it was
/// describing — refusing to answer an approval prompt because the record was
/// locked would be a strictly worse app.
class DecisionRecorder {
  DecisionRecorder(this._ref);

  final Ref _ref;
  final _log = AppLogger.named('decisions');

  /// The user (or an agent acting through `session_answer`) answered an
  /// agent's on-screen approval prompt.
  ///
  /// [effect] is the agent's **own words** for what the key does, off its own
  /// prompt — never our description of what we think it authorised. A denial
  /// is recorded as [DecisionKind.approachRejected]: what was refused is as
  /// load-bearing as what was allowed, and filing it under "approval granted"
  /// would make the record say the opposite of what happened.
  DecisionRecord? recordApproval({
    required String sessionId,
    required bool granted,
    required String effect,
    String? answerLabel,
    String decidedBy = 'the user',
    String? decidedBySessionId,
  }) => _append(
    sessionId: sessionId,
    kind: granted
        ? DecisionKind.approvalGranted
        : DecisionKind.approachRejected,
    summary: effect,
    detail: answerLabel == null
        ? null
        : 'Answered "$answerLabel" at the agent\'s own prompt.',
    decidedBy: decidedBy,
    recordedBySessionId: decidedBySessionId,
    // No id: the prompt is drawn by another program and is gone the moment it
    // is answered, so there is nothing to name.
    origin: DecisionOrigin.approvalPrompt,
  );

  /// A verification run reached a verdict — `verification_finish`, and nothing
  /// else.
  ///
  /// [attribution] is the phrase G3 already derives from the two session ids,
  /// carried through verbatim so the packet says whether the verifier was the
  /// author. A pass nobody independently checked and a pass somebody did are
  /// worth different amounts, and the reader of a handoff is exactly the
  /// person who cannot tell them apart on their own.
  DecisionRecord? recordVerificationVerdict({
    required String sessionId,
    required String runId,
    required String verdict,
    required String title,
    String? reason,
    String? attribution,
    String? producedBySessionId,
  }) => _append(
    sessionId: sessionId,
    kind: DecisionKind.verificationVerdict,
    summary: reason == null || reason.trim().isEmpty
        ? '$verdict — $title'
        : '$verdict — $title. $reason',
    detail: attribution,
    decidedBy: producedBySessionId == null
        ? null
        : _agentNameFor(producedBySessionId),
    recordedBySessionId: producedBySessionId,
    origin: DecisionOrigin.verificationRun,
    originId: runId,
  );

  /// Somebody asked for a checkpoint **and said what it was for**.
  ///
  /// The label is the whole reason this is a decision. A turn checkpoint
  /// records that time passed; one a person or an agent asked for, with a
  /// reason attached, records that a tree state was chosen — the fourth thing
  /// the gap analysis says the checkpoint chain cannot currently express.
  DecisionRecord? recordCheckpoint({
    required String sessionId,
    required String checkpointId,
    required String label,
    String? decidedBy,
    String? decidedBySessionId,
  }) => _append(
    sessionId: sessionId,
    kind: DecisionKind.checkpointMarked,
    summary: label,
    decidedBy: decidedBy,
    recordedBySessionId: decidedBySessionId,
    origin: DecisionOrigin.checkpoint,
    originId: checkpointId,
  );

  /// An agent recorded a decision deliberately, through the `decision_record`
  /// tool.
  ///
  /// The caller has already restricted [kind] to what an agent is entitled to
  /// assert about its own reasoning — see `DecisionControlTools`, which will
  /// not let an agent write an approval the user never gave.
  DecisionRecord? recordFromAgent({
    required String sessionId,
    required DecisionKind kind,
    required String summary,
    String? detail,
    String? decidedBySessionId,
  }) => _append(
    sessionId: sessionId,
    kind: kind,
    summary: summary,
    detail: detail,
    decidedBy: decidedBySessionId == null
        ? null
        : _agentNameFor(decidedBySessionId),
    recordedBySessionId: decidedBySessionId,
    origin: DecisionOrigin.decisionTool,
  );

  /// The user wrote one down by hand, in the Decisions panel.
  ///
  /// The fifth explicit act, and the only one whose author is a person typing.
  /// [kind] is restricted by the panel to what the writer is entitled to
  /// assert with nothing behind it — a constraint, a rejected approach, and
  /// (unlike `DecisionControlTools`) an approval, because the user granting one
  /// is the user's own statement rather than an agent's claim about them. A
  /// verdict and a marked checkpoint stay out for the reason they stay out of
  /// the tool: both would point at a run or a checkpoint that does not exist.
  DecisionRecord? recordByHand({
    required String sessionId,
    required DecisionKind kind,
    required String summary,
    String? detail,
    String decidedBy = 'the user',
  }) => _append(
    sessionId: sessionId,
    kind: kind,
    summary: summary,
    detail: detail,
    decidedBy: decidedBy,
    // No recording session and no origin id: nobody's agent wrote this, and
    // there is no other record to name.
    origin: DecisionOrigin.userEntry,
  );

  /// Stamps the decision with the clock and appends it.
  ///
  /// A blank summary is refused rather than stored: a row with nothing in it
  /// would count towards "this session recorded 4 decisions" while telling the
  /// reader nothing, which is the one failure mode worse than an empty record.
  DecisionRecord? _append({
    required String sessionId,
    required DecisionKind kind,
    required String summary,
    required DecisionOrigin origin,
    String? detail,
    String? decidedBy,
    String? recordedBySessionId,
    String? originId,
  }) {
    if (summary.trim().isEmpty) return null;
    try {
      final appended = _ref
          .read(decisionRecordDaoProvider)
          .append(
            DecisionRecord(
              sessionId: sessionId,
              kind: kind,
              summary: summary.trim(),
              detail: detail,
              decidedBy: decidedBy,
              recordedBySessionId: recordedBySessionId,
              origin: origin,
              originId: originId,
              recordedAt: _ref.read(clockProvider).nowUtc(),
            ),
          );
      // Every write, not just the panel's: an approval answered while the
      // panel is open must show up in it, and the panel is the only reader.
      _ref.read(decisionsRevisionProvider.notifier).bump();
      return appended;
    } catch (error, stack) {
      _log.warning(
        'Could not record a decision for session $sessionId.',
        error,
        stack,
      );
      return null;
    }
  }

  /// The display name of the agent running [sessionId], for the attribution
  /// line, or null when it cannot be resolved.
  ///
  /// A name rather than an id because the packet's reader has no way to look
  /// an id up, and null rather than a guess because "not recorded" is a state
  /// the packet renders honestly.
  String? _agentNameFor(String sessionId) {
    final session = _ref.read(sessionDaoProvider).getById(sessionId);
    if (session == null) return null;
    final agentId = _ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId)
        ?.agentId;
    return agentId == null
        ? null
        : _ref.read(agentRegistryProvider).displayNameFor(agentId);
  }
}

final decisionRecorderProvider = Provider<DecisionRecorder>(
  (ref) => DecisionRecorder(ref),
);
