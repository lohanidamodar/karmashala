/// What a run concluded. [inconclusive] is a first-class answer: an agent that
/// never reached the page must not pick a pass or fail it did not observe.
///
/// Shared rather than owned by one feature: a verification run, a project
/// check and a gate all record the same three answers, and two copies of this
/// enum would be two vocabularies that can disagree.
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
