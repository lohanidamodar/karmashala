import 'package:karmashala_session/events.dart';

/// An answered approval prompt, as the decision record files it: a grant as
/// `approvalGranted`, a denial as a rejection, [effect] in the agent's own
/// words. Null for a blank [effect], which would count towards a total while
/// telling the reader nothing. The app and the session host file the same
/// record, whichever of them typed the answer.
DecisionRecord? approvalDecisionRecord({
  required String sessionId,
  required bool granted,
  required String effect,
  required DateTime recordedAt,
  String? answerLabel,
  String decidedBy = 'the user',
  String? decidedBySessionId,
}) {
  if (effect.trim().isEmpty) return null;
  return DecisionRecord(
    sessionId: sessionId,
    kind: granted
        ? DecisionKind.approvalGranted
        : DecisionKind.approachRejected,
    summary: effect.trim(),
    detail: answerLabel == null
        ? null
        : 'Answered "$answerLabel" at the agent\'s own prompt.',
    decidedBy: decidedBy,
    recordedBySessionId: decidedBySessionId,
    // No id: the prompt is drawn by another program and is gone the moment it
    // is answered, so there is nothing to name.
    origin: DecisionOrigin.approvalPrompt,
    recordedAt: recordedAt,
  );
}
