import '../domain/session_verdict.dart';

/// What a surface offers beside a verdict, when it offers anything.
///
/// A review costs tokens and starts a second agent, so "always show the button"
/// is not a neutral default — it is a standing invitation to spend both on a
/// question that may already be answered, or already being answered. The rule
/// lives here, in one place, because two hosts read it (the strip above the
/// composer and the session bar under the terminal) and a button that appeared
/// in one and not the other would be a bug invisible from either file.
enum ReviewInvitation {
  /// Nothing has ever checked this work.
  check('Check this'),

  /// A run names this session already, so this one would be another.
  checkAgain('Check again');

  const ReviewInvitation(this.label);

  /// The words on the control. Short because the strip is narrow and the
  /// tooltip is where the agent and the permission cap are named.
  final String label;

  /// What [state] wants offered beside it, or null when it wants nothing.
  ///
  /// **The words turn on whether a run exists, not on what it concluded.** A
  /// pass, a fail, an abandoned run and a verdict word this build cannot read
  /// are four different facts, but "again" is honestly true of all four, and
  /// "Check this" sitting under "Checked: pass" would be the strip arguing with
  /// itself in two words. A pass is still worth re-checking — a pass the author
  /// recorded about its own work is exactly what an independent review exists
  /// to replace — it just is not worth asking for in the words of a session
  /// nobody has looked at.
  ///
  /// The one refusal is a run that is open on a live session: the check the
  /// button would start is the check already running, and the second verdict
  /// would supersede the first purely by finishing later.
  ///
  /// Exhaustive over the seven states on purpose — an eighth will not compile
  /// until somebody decides whether it wants a button.
  static ReviewInvitation? forVerdict(SessionVerdictState state) =>
      switch (state) {
        SessionVerdictState.notRecorded => check,
        SessionVerdictState.inProgress => null,
        SessionVerdictState.unfinished ||
        SessionVerdictState.verdictNotRecorded ||
        SessionVerdictState.pass ||
        SessionVerdictState.fail ||
        SessionVerdictState.inconclusive => checkAgain,
      };
}
