/// Who produced a verdict, relative to the work the verdict is about.
///
/// The question G3 exists to answer: `VerificationService` collects real
/// evidence, but until now nothing recorded *who graded it*, and in practice
/// the agent calling `verification_start`/`verification_finish` is the agent
/// that wrote the code. A self-graded exam and an independently checked one
/// are worth different amounts, and a surface that shows the same chip for
/// both is hiding the difference.
///
/// Always **derived**, never stored: a boolean column beside the two session
/// ids is a third source of truth that drifts the first time either id is
/// rewritten. The producer id is the only fact persisted.
enum VerdictAttribution {
  /// The session that did the work also produced the verdict.
  author('Self-verified', 'by the author', 'self'),

  /// A different session produced the verdict.
  independent('Independently verified', 'by another session', 'independent'),

  /// Nobody recorded who produced it — the honest answer for every row written
  /// before attribution existed, and for a run that names no subject to
  /// compare a producer against.
  ///
  /// Deliberately its own state rather than folded into either neighbour.
  /// Reading it as [author] slanders a verdict that may well be independent;
  /// reading it as [independent] is the lie that makes a self-graded pass look
  /// checked. "Not recorded" is a gap you can see.
  notRecorded('Verifier not recorded', 'verifier not recorded', 'unattributed');

  const VerdictAttribution(this.label, this.phrase, this.shortLabel);

  /// Sentence-leading form, for a detail row.
  final String label;

  /// Trailing form, to hang off a verdict: "Pass, by the author".
  final String phrase;

  /// One word, for a chip with no room.
  final String shortLabel;

  bool get isRecorded => this != notRecorded;

  /// Compares the producer against the session the verdict is about.
  ///
  /// A missing subject is as unknowable as a missing producer: with nothing to
  /// compare against, "a different session" cannot be claimed.
  static VerdictAttribution of({
    required String? producerSessionId,
    required String? subjectSessionId,
  }) {
    if (producerSessionId == null || subjectSessionId == null) {
      return notRecorded;
    }
    return producerSessionId == subjectSessionId ? author : independent;
  }
}
