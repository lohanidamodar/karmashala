import '../domain/session_verdict.dart';

/// What a surface offers beside a verdict. In one place because two hosts read
/// it, and a button in one but not the other is invisible from either file.
enum ReviewInvitation {
  /// Nothing has ever checked this work.
  check('Check this'),

  /// A run names this session already, so this one would be another.
  checkAgain('Check again');

  const ReviewInvitation(this.label);

  /// The words on the control — short; the tooltip names the agent and cap.
  final String label;

  /// What [state] wants offered, or null. The words turn on whether a run
  /// exists, not what it concluded; a run open on a live session gets nothing.
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
