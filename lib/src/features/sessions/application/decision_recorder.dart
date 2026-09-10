import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../domain/decision_record.dart';
import 'session_decision_providers.dart';
import 'session_providers.dart';

/// The only way anything writes to a session's decision record.
///
/// One method per **explicit act**, named after the act, so reading this class
/// is reading the complete list of things that can put a row in the record: an
/// agent reading a handoff packet has no way to check a decision, so every row
/// has to be traceable to somebody actually deciding something rather than to a
/// heuristic that ran over a conversation.
///
/// **Nothing here reads prose** — no method takes a transcript, a message or a
/// terminal buffer. A record that is sometimes invented is worse than none,
/// because the reader cannot tell which row is which. Every write is
/// best-effort and returns `null` rather than throwing: a decision that could
/// not be recorded must never break the act it was describing.
class DecisionRecorder {
  DecisionRecorder(this._ref);

  final Ref _ref;
  final _log = AppLogger.named('decisions');

  /// The user (or an agent acting through `session_answer`) answered an agent's
  /// on-screen approval prompt. [effect] is the agent's **own words** for what
  /// the key does, never our description of it. A denial is recorded as
  /// [DecisionKind.approachRejected]: what was refused is as load-bearing as
  /// what was allowed, and filing it under "approval granted" would make the
  /// record say the opposite of what happened.
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
  /// else. [attribution] carries G3's phrase verbatim so the packet says
  /// whether the verifier was the author: a pass nobody independently checked
  /// and one somebody did are worth different amounts.
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

  /// Somebody asked for a checkpoint **and said what it was for**. The label is
  /// the whole reason this is a decision: a turn checkpoint records that time
  /// passed, one asked for with a reason records that a tree state was chosen.
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
  /// tool. The caller has already restricted [kind] to what an agent is
  /// entitled to assert about its own reasoning — see `DecisionControlTools`.
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

  /// The user wrote one down by hand, in the Decisions panel — the only act
  /// whose author is a person typing. [kind] is restricted by the panel to what
  /// the writer may assert with nothing behind it, including an approval,
  /// because the user granting one is their own statement rather than an
  /// agent's claim about them. A verdict and a marked checkpoint stay out: both
  /// would point at a run or a checkpoint that does not exist.
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

  /// Stamps the decision with the clock and appends it. A blank summary is
  /// refused rather than stored: a row with nothing in it would count towards
  /// "this session recorded 4 decisions" while telling the reader nothing.
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
  /// line, or null when it cannot be resolved — a name rather than an id
  /// because the packet's reader has no way to look an id up, and null rather
  /// than a guess.
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
