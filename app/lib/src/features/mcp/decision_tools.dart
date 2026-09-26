import 'package:riverpod/riverpod.dart';

import '../sessions/application/decision_recorder.dart';
import 'package:karmashala_verification/verification.dart';
import 'dart:async';

// `decision_record` itself is the server's (`DecisionToolSet`); what stays
// here is the verdict a finished run in this app writes.

/// Writes a finished run's verdict to the **subject** session's decision record,
/// not the verifier's. An unfinished or unattached run writes nothing.
void recordFinishedVerdict(ProviderContainer container, VerificationRun? run) {
  if (run == null) return;
  final subject = run.sessionId;
  final verdict = run.verdict;
  if (subject == null || verdict == null) return;
  final recording = container
      .read(decisionRecorderProvider)
      .recordVerificationVerdict(
        sessionId: subject,
        runId: run.id,
        verdict: verdict.label,
        title: run.title,
        reason: run.reason,
        attribution: 'Verdict ${run.attribution.phrase}.',
        producedBySessionId: run.producedBySessionId,
      );
  unawaited(recording);
}
