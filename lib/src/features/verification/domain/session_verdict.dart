import 'verification_run.dart';

/// What a session's verification record says, for a surface with room for one
/// word. Seven states, not [VerificationVerdict]'s three, because an absence is
/// not a pass: every gap gets its own words and a neutral colour of its own.
enum SessionVerdictState {
  /// Nothing ever checked this session — a gap in the record, not a finding.
  /// "Not checked", not "No check recorded": a gate run in a terminal reports
  /// to nothing, so the label names the work's state, not a filing cabinet's.
  notRecorded('Not checked'),

  /// A run is open and the session is still live, so it is being recorded.
  inProgress('Checking…'),

  /// A run nothing finished, whose owning session has ended — so nothing will.
  unfinished('Check unfinished'),

  /// A verdict word this build cannot read — its own state, not [notRecorded],
  /// which would hide evidence that exists.
  verdictNotRecorded('Verdict not recorded'),

  pass('Checked: pass'),
  fail('Checked: fail'),
  inconclusive('Checked: inconclusive');

  const SessionVerdictState(this.label);

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
          'not a verdict about the work. Run checks runs the repository\'s '
          'project checks and records the result here; an agent records one '
          'with checks_run or verification_start/finish. A build or a test '
          'suite run by hand in a terminal reports to nothing.',
    inProgress =>
      'A run is open and this session is still live, so it is '
          'being recorded now.',
    unfinished =>
      'A run was started and nothing ever finished it. The '
          'session that owned it has ended, so nothing will.',
    verdictNotRecorded =>
      'The run finished carrying a verdict this build '
          'cannot read.',
    pass => 'The run concluded that it works.',
    fail => 'The run concluded that it does not work.',
    inconclusive =>
      'The run could not tell — which is an answer, not a '
          'missing one.',
  };
}

/// One session's verification standing: the state, and the run it came from.
class SessionVerdict {
  const SessionVerdict({required this.state, this.run, this.runCount = 0});

  final SessionVerdictState state;

  final VerificationRun? run;

  /// How many runs name this session, so the tooltip can say "most recent".
  final int runCount;

  static const none = SessionVerdict(state: SessionVerdictState.notRecorded);

  /// Reads [runs] newest-first; the newest supersedes. [sessionHasEnded]
  /// settles [VerificationRun.isOpen]: once the owner ended, it means abandoned.
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
            // Admitting it beats picking whichever of the three is closest.
            null => SessionVerdictState.verdictNotRecorded,
          };
    return SessionVerdict(state: state, run: run, runCount: runs.length);
  }
}
