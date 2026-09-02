import '../../verification/domain/verification_run.dart';
import 'follow_up.dart';
import 'session_ending.dart';

/// What a session's verification runs still owe the reader.
///
/// Derived from **typed** fields only — `VerificationRun.isOpen` and
/// `VerificationRun.verdict`, which is an enum. Nothing here parses a sentence,
/// and nothing dereferences a `DecisionRecord.originId`, which
/// `decision_record.dart` states is never resolved by anything.
enum VerificationResidue {
  /// Every run this session started reached a verdict, and every verdict was a
  /// pass — or there were no runs at all. **The two are the same answer here
  /// and that is deliberate**: an empty record means nobody verified anything,
  /// which is not evidence about the session, so it cannot be turned into a
  /// notice claiming the work is unchecked.
  none,

  /// A run was started and nothing ever finished it.
  abandoned,

  /// A run reached a verdict of fail or inconclusive.
  notPassed,
}

/// What [runs] leave outstanding.
///
/// Ranked rather than merged: a stated failure outranks an unfinished check,
/// because a `fail` names a concrete defect and an open run only names an
/// absence. A session with both is described by the sharper of the two.
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
///
/// **The whole rule, and it is pure on purpose** — no database, no agent, no
/// window, exactly like `shouldDetachOnClose`. The caller supplies the two
/// observations; everything interesting about this feature is the table below,
/// so the table is a function anyone can read in one sitting and a test can
/// exercise exhaustively.
///
/// The four endings get four different answers, and three of them are silence:
///
/// * **[SessionEnding.handedOff] — never.** A handoff *is* the follow-up,
///   already taken: the work is running somewhere else with a packet in its
///   hands. Raising a notice here would be the app nagging about something it
///   watched the user finish.
/// * **[SessionEnding.cancelled] — never.** The user stopped it on purpose.
///   Answering an explicit instruction with a reminder is the app arguing with
///   its owner.
/// * **[SessionEnding.lostTrack] — never.** Not an ending. See
///   [SessionEnding.lostTrack]; a follow-up raised here would be a guess
///   wearing the clothes of an observation.
/// * **[SessionEnding.failed] — always.** The one thing nobody notices in a
///   workspace running twenty agents, and the direction it is safe to be wrong
///   in: a notice the user dismisses costs a click, and a crash the user never
///   sees costs the afternoon.
/// * **[SessionEnding.completed] — only if something was left.** A clean finish
///   with nothing outstanding is a finish, and the app should say nothing at
///   all about it.
///
/// Note the asymmetry between the last two: a failure is reported *whatever* it
/// verified, because the run's own verdict is the less important fact once the
/// session it was checking stopped in error.
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
