/// The kinds of action a run records. Parsed by name with an [other] fallback,
/// never `values.byName`, which throws on a kind a newer build wrote.
enum VerificationStepKind {
  navigate('Navigate'),
  click('Click'),
  type('Type'),
  key('Key'),
  evaluate('Evaluate'),
  find('Find'),
  screenshot('Screenshot'),
  capture('Capture'),
  launch('Launch'),
  tap('Tap'),
  swipe('Swipe'),
  uiDump('UI tree'),
  logcat('Logcat'),
  note('Note'),
  verdict('Verdict'),
  other('Action');

  const VerificationStepKind(this.label);

  final String label;

  static VerificationStepKind parse(String? value) {
    for (final kind in values) {
      if (kind.name == value) return kind;
    }
    return VerificationStepKind.other;
  }
}

/// One recorded action, in the order it happened. [ordinal] is the run-local
/// sequence number and the step's identity — artifacts point back by ordinal.
class VerificationStep {
  const VerificationStep({
    required this.ordinal,
    required this.kind,
    required this.summary,
    required this.at,
    this.detail,
    this.ok = true,
  });

  final int ordinal;
  final VerificationStepKind kind;

  /// One line: what was done, and to what.
  final String summary;

  /// Anything longer — an expression, an error message, a returned value.
  final String? detail;

  final DateTime at;

  /// Whether the action succeeded. A failed action is still a step: "the click
  /// was refused because a banner covered the button" is evidence.
  final bool ok;
}
