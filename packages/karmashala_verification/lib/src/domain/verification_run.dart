import 'package:karmashala_core/verdicts.dart';

import 'code_identity.dart';
import 'verdict_attribution.dart';
import 'verification_artifact.dart';
import 'verification_step.dart';
import 'verification_target.dart';

// The three answers are shared vocabulary rather than this feature's alone;
// callers that have always found `VerificationVerdict` here still do.
export 'package:karmashala_core/verdicts.dart';

/// A recorded attempt to prove that something works. A run with no verdict is
/// still open — being recorded right now, or abandoned.
class VerificationRun {
  const VerificationRun({
    required this.id,
    required this.title,
    required this.target,
    required this.startedAt,
    required this.artifactDirectory,
    this.sessionId,
    this.producedBySessionId,
    this.finishedAt,
    this.verdict,
    this.reason,
    this.steps = const [],
    this.artifacts = const [],
    this.identity,
  });

  final String id;
  final String title;
  final VerificationTarget target;

  /// The session this run belongs to, or null. A plain column, never a foreign
  /// key: evidence must outlive the session.
  final String? sessionId;

  /// Who recorded the run and signed off; equal to [sessionId] is self-graded.
  final String? producedBySessionId;

  final DateTime startedAt;
  final DateTime? finishedAt;
  final VerificationVerdict? verdict;

  /// One or two sentences saying *why* the verdict is what it is.
  final String? reason;

  /// Where this run's files live, absolute.
  final String artifactDirectory;

  final List<VerificationStep> steps;
  final List<VerificationArtifact> artifacts;

  /// The code this ran on, or null for a run recorded before that was kept
  /// or with no checkout to read.
  final CodeIdentity? identity;

  VerdictAttribution get attribution => VerdictAttribution.of(
    producerSessionId: producedBySessionId,
    subjectSessionId: sessionId,
  );

  /// Still recording (or abandoned): nothing has finished it.
  bool get isOpen => finishedAt == null;

  Duration? get duration => finishedAt?.difference(startedAt);

  VerificationRun copyWith({
    String? title,
    String? sessionId,
    String? producedBySessionId,
    DateTime? finishedAt,
    VerificationVerdict? verdict,
    String? reason,
    List<VerificationStep>? steps,
    List<VerificationArtifact>? artifacts,
    CodeIdentity? identity,
  }) => VerificationRun(
    id: id,
    title: title ?? this.title,
    target: target,
    startedAt: startedAt,
    artifactDirectory: artifactDirectory,
    sessionId: sessionId ?? this.sessionId,
    producedBySessionId: producedBySessionId ?? this.producedBySessionId,
    finishedAt: finishedAt ?? this.finishedAt,
    verdict: verdict ?? this.verdict,
    reason: reason ?? this.reason,
    steps: steps ?? this.steps,
    artifacts: artifacts ?? this.artifacts,
    identity: identity ?? this.identity,
  );
}
