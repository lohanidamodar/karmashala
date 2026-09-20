import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import 'package:karmashala_session/events.dart';
import 'session_decision_providers.dart';
import 'session_providers.dart';

/// The only way anything writes to a session's decision record. **Nothing here
/// reads prose**, and every write is best-effort rather than throwing.
class DecisionRecorder {
  DecisionRecorder(this._ref);

  final Ref _ref;
  final _log = AppLogger.named('decisions');

  /// The user (or an agent through `session_answer`) answered an approval
  /// prompt. [effect] is the agent's own words; a denial files as a rejection.
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
  /// else. [attribution] says whether the verifier was also the author.
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

  /// Somebody asked for a checkpoint **and said what it was for**: the label
  /// is what makes it a decision rather than a record that time passed.
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
  /// tool; the caller has already restricted [kind] to what it may assert.
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

  /// A scheduled resume fired: the approval was given in advance, so the
  /// record says who armed it and what was typed with nobody there.
  DecisionRecord? recordScheduledResume({
    required String sessionId,
    required String resumeId,
    required String summary,
    required String scheduledBy,
    String? detail,
  }) => _append(
    sessionId: sessionId,
    kind: DecisionKind.approvalGranted,
    summary: summary,
    detail: detail,
    decidedBy: scheduledBy,
    origin: DecisionOrigin.scheduledResume,
    originId: resumeId,
  );

  /// The user wrote one down by hand — the only act whose author is a person
  /// typing, so the panel restricts [kind] to what they can assert alone.
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

  /// Copies [from]'s record into [into] — what a handoff or a fork does, so a
  /// chain of sessions accumulates its decisions rather than starting empty
  /// each time. The packet already *quotes* them; this makes them readable by
  /// the tools, and by the next handoff after this one.
  ///
  /// Each row keeps who decided it and when: a carried decision is the same
  /// decision, and re-stamping it with now would say the new session made it.
  /// [recordedBySessionId] becomes the session it came from, which is where a
  /// reader goes to see the conversation around it.
  int carryForward({required String from, required String into}) {
    if (from == into) return 0;
    try {
      final dao = _ref.read(decisionRecordDaoProvider);
      final source = dao.forSession(from);
      for (final decision in source) {
        dao.append(
          DecisionRecord(
            sessionId: into,
            kind: decision.kind,
            summary: decision.summary,
            detail: decision.detail,
            decidedBy: decision.decidedBy,
            recordedBySessionId: decision.recordedBySessionId ?? from,
            origin: decision.origin,
            originId: decision.originId,
            recordedAt: decision.recordedAt,
          ),
        );
      }
      if (source.isNotEmpty) {
        _ref.read(decisionsRevisionProvider.notifier).bump();
        _log.info(
          'Carried ${source.length} decision(s) from $from into $into.',
        );
      }
      return source.length;
    } catch (error, stack) {
      // A continuation that starts with an empty record is worse than one that
      // starts at all: never a reason to fail the launch.
      _log.warning('Could not carry decisions from $from.', error, stack);
      return 0;
    }
  }

  /// Stamps the decision with the clock and appends it. A blank summary is
  /// refused: it would count towards a total while telling the reader nothing.
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

  /// The display name of the agent running [sessionId], or null — a name, not
  /// an id the packet's reader could not look up, and never a guess.
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
