import 'verdict_attribution.dart';
import 'verification_artifact.dart';
import 'verification_step.dart';
import 'verification_target.dart';

/// What the run concluded. [inconclusive] is a first-class answer: an agent
/// that never reached the page must not pick a pass or fail it did not observe.
enum VerificationVerdict {
  pass('Pass'),
  fail('Fail'),
  inconclusive('Inconclusive');

  const VerificationVerdict(this.label);

  final String label;

  static VerificationVerdict? parse(String? value) {
    if (value == null) return null;
    for (final verdict in values) {
      if (verdict.name == value) return verdict;
    }
    return null;
  }
}

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
  );
}
