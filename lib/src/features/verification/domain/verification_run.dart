import 'verification_artifact.dart';
import 'verification_step.dart';
import 'verification_target.dart';

/// What the run concluded.
///
/// [inconclusive] is a first-class answer, not a missing one: an agent that
/// could not reach the page, or whose device went away mid-run, must be able to
/// say so rather than pick between a pass and a fail it did not observe.
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

/// A recorded attempt to prove that something works.
///
/// The unit an agent hands to a human: what was verified, what was done to it,
/// what was captured, and what the agent concluded. A run with no verdict is
/// still open — it is being recorded right now, or it was abandoned.
class VerificationRun {
  const VerificationRun({
    required this.id,
    required this.title,
    required this.target,
    required this.startedAt,
    required this.artifactDirectory,
    this.sessionId,
    this.finishedAt,
    this.verdict,
    this.reason,
    this.steps = const [],
    this.artifacts = const [],
  });

  final String id;
  final String title;
  final VerificationTarget target;

  /// The session this run belongs to, or null when it was started outside one.
  ///
  /// Deliberately a plain column and **not** a foreign key: evidence must
  /// outlive the session that produced it, and `sessions/` is another owner's
  /// table. Reading the session's title is a lookup, not a join.
  final String? sessionId;

  final DateTime startedAt;
  final DateTime? finishedAt;
  final VerificationVerdict? verdict;

  /// One or two sentences saying *why* the verdict is what it is.
  final String? reason;

  /// Where this run's files live, absolute.
  final String artifactDirectory;

  final List<VerificationStep> steps;
  final List<VerificationArtifact> artifacts;

  /// Still recording (or abandoned): nothing has finished it.
  bool get isOpen => finishedAt == null;

  Duration? get duration => finishedAt?.difference(startedAt);

  VerificationRun copyWith({
    String? title,
    String? sessionId,
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
    finishedAt: finishedAt ?? this.finishedAt,
    verdict: verdict ?? this.verdict,
    reason: reason ?? this.reason,
    steps: steps ?? this.steps,
    artifacts: artifacts ?? this.artifacts,
  );
}
