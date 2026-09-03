import 'verification_run.dart';

/// What a session's verification record says, for a surface with room for one
/// word.
///
/// Seven states rather than the three [VerificationVerdict] has, and the four
/// extra ones are the whole point: **an absence is not a pass.** A strip that
/// drew nothing when nothing had been checked would read, to anyone scanning
/// it, exactly like a strip that had checked and found nothing wrong. So every
/// gap in the record gets its own words and its own neutral colour, and none of
/// them is allowed to borrow a verdict's.
enum SessionVerdictState {
  /// Nothing ever checked this session. A gap in the record, not a finding
  /// about the work — the same reading `VerificationResidue.none` refuses to
  /// turn into a notice.
  ///
  /// **"Not checked", not "No check recorded".** The owner read the old wording
  /// as *"Karmashala failed to record the checks you ran"* and asked why it
  /// never changed while `flutter analyze` and `flutter test` were being run all
  /// day. They cannot change it: a gate run in a terminal reports to nothing,
  /// and a run only exists when an agent wraps its work in `verification_start`
  /// and `verification_finish`. So the label names the state of the *work*
  /// rather than the state of a filing cabinet, and [explanation] says what
  /// would fill it.
  notRecorded('Not checked'),

  /// A run is open and the session is still live, so it is being recorded.
  inProgress('Checking…'),

  /// A run was started and nothing finished it, and the session that owned it
  /// has ended — so nothing will.
  unfinished('Check unfinished'),

  /// The run finished carrying a verdict word this build cannot read.
  ///
  /// Its own state rather than folded into [notRecorded]: a run was recorded,
  /// and saying otherwise would hide evidence that exists.
  verdictNotRecorded('Verdict not recorded'),

  pass('Checked: pass'),
  fail('Checked: fail'),
  inconclusive('Checked: inconclusive');

  const SessionVerdictState(this.label);

  /// The words on the strip.
  final String label;

  /// Whether this is a verdict at all, as opposed to a hole where one would be.
  bool get isVerdict => switch (this) {
    pass || fail || inconclusive => true,
    notRecorded || inProgress || unfinished || verdictNotRecorded => false,
  };

  /// What the state means, in a sentence, for the tooltip.
  String get explanation => switch (this) {
    notRecorded =>
      'No verification run names this session. That is a gap in the record, '
          'not a verdict about the work. Only an agent records one — '
          'verification_start around the work, verification_finish with a '
          'verdict; a build or a test suite run in a terminal reports to '
          'nothing on its own.',
    inProgress => 'A run is open and this session is still live, so it is '
        'being recorded now.',
    unfinished => 'A run was started and nothing ever finished it. The '
        'session that owned it has ended, so nothing will.',
    verdictNotRecorded => 'The run finished carrying a verdict this build '
        'cannot read.',
    pass => 'The run concluded that it works.',
    fail => 'The run concluded that it does not work.',
    inconclusive => 'The run could not tell — which is an answer, not a '
        'missing one.',
  };
}

/// One session's verification standing: the state, and the run it came from.
class SessionVerdict {
  const SessionVerdict({required this.state, this.run, this.runCount = 0});

  final SessionVerdictState state;

  /// The run being reported, or null when there is none to report.
  final VerificationRun? run;

  /// How many runs name this session at all, so the tooltip can say that the
  /// one word above it is the most recent of several rather than the only one.
  final int runCount;

  static const none = SessionVerdict(state: SessionVerdictState.notRecorded);

  /// Reads [runs] — newest first, as `VerificationDao.listRuns` returns them.
  ///
  /// **The newest run supersedes.** A fail that was fixed and checked again
  /// reads as the pass it now is, which is the whole reason anybody runs a
  /// check twice; the count of what came before is kept for the tooltip rather
  /// than merged into the word. That is deliberately *not*
  /// `verificationResidueIn`'s ranking, which answers a different question —
  /// "what is still owed" — and which folds "everything passed" together with
  /// "nothing was checked", the one conflation this type exists to prevent.
  ///
  /// [sessionHasEnded] settles the only ambiguity in the data:
  /// [VerificationRun.isOpen] means "being recorded right now, **or**
  /// abandoned", and once the session that owned the run has ended only the
  /// second reading is left. Same rule as
  /// `FollowUpReason.verificationAbandoned`, and it is stated in one place
  /// here so the two surfaces cannot come to read the same row differently.
  factory SessionVerdict.of(
    List<VerificationRun> runs, {
    required bool sessionHasEnded,
  }) {
    if (runs.isEmpty) return none;
    final run = runs.first;
    final state = run.isOpen
        ? (sessionHasEnded
              ? SessionVerdictState.unfinished
              : SessionVerdictState.inProgress)
        : switch (run.verdict) {
            VerificationVerdict.pass => SessionVerdictState.pass,
            VerificationVerdict.fail => SessionVerdictState.fail,
            VerificationVerdict.inconclusive =>
              SessionVerdictState.inconclusive,
            // Finished, with a word written by a build that knew one this does
            // not. Admitting that beats picking whichever of the three is
            // closest — see `VerificationStepKind.parse` for the same choice.
            null => SessionVerdictState.verdictNotRecorded,
          };
    return SessionVerdict(state: state, run: run, runCount: runs.length);
  }
}
