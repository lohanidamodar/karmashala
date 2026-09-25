/// The producer recorded for a verdict the app itself read off an exit code.
/// Not a session id — no session is ever given this one.
const String kAppVerifierId = 'karmashala';

/// Who produced a verdict, relative to the work it is about — a self-graded
/// exam and an independently checked one are worth different amounts. Always
/// derived from the two session ids, never stored: a column would drift.
enum VerdictAttribution {
  /// The session that did the work also produced the verdict.
  author('Self-verified', 'by the author', 'self'),

  /// A different session produced the verdict.
  independent('Independently verified', 'by another session', 'independent'),

  /// Karmashala produced it from an exit code it observed — a check the app
  /// ran, whoever asked for it. Independent of the work by construction.
  app('Checked by Karmashala', 'by Karmashala', 'app'),

  /// Nobody recorded who produced it — its own state, because [author] would
  /// slander it and [independent] would make a self-graded pass look checked.
  notRecorded('Verifier not recorded', 'verifier not recorded', 'unattributed');

  const VerdictAttribution(this.label, this.phrase, this.shortLabel);

  final String label;

  /// Trailing form, to hang off a verdict: "Pass, by the author".
  final String phrase;

  /// One word, for a chip with no room.
  final String shortLabel;

  bool get isRecorded => this != notRecorded;

  /// Whether someone other than the author produced it.
  bool get isIndependent => this == independent || this == app;

  /// Compares the producer against the session the verdict is about; a missing
  /// subject is as unknowable as a missing producer.
  static VerdictAttribution of({
    required String? producerSessionId,
    required String? subjectSessionId,
  }) {
    if (producerSessionId == kAppVerifierId) return app;
    if (producerSessionId == null || subjectSessionId == null) {
      return notRecorded;
    }
    return producerSessionId == subjectSessionId ? author : independent;
  }
}
