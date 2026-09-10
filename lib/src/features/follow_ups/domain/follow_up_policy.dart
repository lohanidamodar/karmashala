import '../../verification/domain/verification_run.dart';
import 'follow_up.dart';
import 'session_ending.dart';

/// What a session's verification runs still owe the reader, derived from typed
/// fields only — nothing here parses a sentence.
enum VerificationResidue {
  /// Every run passed, **or** there were no runs: the same answer deliberately,
  /// because an empty record is not evidence that the work is unchecked.
  none,

  /// A run was started and nothing ever finished it.
  abandoned,

  /// A run reached a verdict of fail or inconclusive.
  notPassed,
}

/// What [runs] leave outstanding. Ranked rather than merged: a stated failure
/// names a defect, an open run only names an absence.
VerificationResidue verificationResidueIn(Iterable<VerificationRun> runs) {
  var residue = VerificationResidue.none;
  for (final run in runs) {
    if (run.isOpen) {
      residue = VerificationResidue.abandoned;
      continue;
    }
    if (run.verdict != null && run.verdict != VerificationVerdict.pass) {
      return VerificationResidue.notPassed;
    }
  }
  return residue;
}

/// Whether a session that ended leaves the user something to come back to.
/// Pure on purpose — the caller supplies both observations, so the table below
/// is the whole feature and a test can exercise it exhaustively.
FollowUpReason? followUpFor({
  required SessionEnding ending,
  VerificationResidue verification = VerificationResidue.none,
}) => switch (ending) {
  SessionEnding.handedOff ||
  SessionEnding.cancelled ||
  SessionEnding.lostTrack ||
  // An ending we cannot name is one we cannot reason about. Silence is the
  // conservative answer and the one this app's standing rule asks for.
  SessionEnding.unrecognised => null,
  SessionEnding.failed => FollowUpReason.endedInFailure,
  SessionEnding.completed => switch (verification) {
    VerificationResidue.notPassed => FollowUpReason.verificationNotPassed,
    VerificationResidue.abandoned => FollowUpReason.verificationAbandoned,
    VerificationResidue.none => null,
  },
};
