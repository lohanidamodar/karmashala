import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/util/clock_provider.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/domain/session.dart';
import '../../sessions/domain/session_lineage.dart';
import '../../verification/application/verification_providers.dart';
import '../../verification/domain/verification_run.dart';
import '../data/follow_up_dao.dart';
import '../domain/follow_up.dart';
import '../domain/follow_up_policy.dart';
import '../domain/session_ending.dart';
import 'follow_up_providers.dart';

/// The only thing that raises and retires follow-ups.
///
/// ## What it is allowed to do
///
/// Read the workspace, and write to its own table. That is the entire list, and
/// the restriction is the feature rather than an oversight: an environment that
/// runs many agents is one wrong line away from being an environment that
/// *starts* agents on its own, and this class is where that line would go.
///
/// So it holds no launcher, no engine and no session-actions reference — there
/// is deliberately no path from here to anything that can start a process —
/// and `follow_up_service_test.dart` asserts that a sweep leaves every session
/// row exactly as it found it. What it produces is an offer; the user takes it.
///
/// ## Why it is a sweep rather than a callback
///
/// A session's row is the durable half of the signal. A row that says `failed`
/// still says so tomorrow, so a follow-up can be noticed after a restart rather
/// than only in the instant the session died — which is the case that matters,
/// because the instant a session dies is exactly when nobody is looking.
class FollowUpService {
  FollowUpService(this._ref);

  final Ref _ref;
  final _log = AppLogger.named('followups');

  /// `'<sessionId>/<ending>'` for every ending that has **ever** produced a
  /// follow-up, whether it is still open or long dismissed.
  ///
  /// Seeded once from the table and kept in memory, and both halves matter.
  /// Kept, because the sweep runs on every session-revision bump and the
  /// alternative is a query per ended session per bump — hundreds, on a
  /// synchronous database, on the UI thread. Including *resolved* rows, because
  /// the row that raised the notice still says `failed` forever: a guard that
  /// only looked for an open follow-up would re-raise a dismissed one a second
  /// later, which is the app overruling its user.
  late final Set<String> _considered = _dao.raisedEndings();

  FollowUpDao get _dao => _ref.read(followUpDaoProvider);

  /// One pass over the workspace the caller has already read.
  ///
  /// Takes the session list rather than fetching it so the caller's own read is
  /// reused, and so the two things this does — raise, and retire — see exactly
  /// the same workspace.
  ///
  /// Cost: one query for the open list, plus one insert per genuinely new
  /// ending and one update per follow-up that has moved on. Whether a session
  /// was handed on is answered from the list itself, in one pass, rather than
  /// with a `childrenOf` query per session.
  ///
  /// Returns whether anything actually changed, so a caller can leave the list
  /// alone when a pass said the same thing again — which is nearly every pass.
  bool sweep(List<Session> sessions) {
    final carriedForward = _carriedForward(sessions);
    var changed = false;

    for (final session in sessions) {
      final ending = endingOfStatus(session.status);
      if (ending == null) continue;
      final raised = notice(
        sessionId: session.id,
        ending: ending,
        carriedForward: carriedForward.contains(session.id),
        session: session,
      );
      changed = changed || raised != null;
    }

    return _retireWhatMovedOn(sessions, carriedForward) || changed;
  }

  /// A session ended. Raise a follow-up if the rule says one is owed.
  ///
  /// Returns null in the ordinary case — most endings owe nothing, and saying
  /// so cheaply is what lets this be called from a poll.
  ///
  /// [carriedForward] is passed in rather than looked up because [sweep]
  /// already knows it for the whole workspace; a caller that does not know
  /// leaves it false and the next sweep retires the follow-up instead.
  FollowUp? notice({
    required String sessionId,
    required SessionEnding ending,
    bool carriedForward = false,
    Session? session,
  }) {
    try {
      final row = session ?? _ref.read(sessionDaoProvider).getById(sessionId);
      // The same silence every other action in this app gives for a session
      // that no longer resolves. Never an exception, and never a launch.
      if (row == null) return null;

      // A handoff *is* the follow-up, already taken. Applied here rather than
      // inside the rule because it outranks whatever the row's own status says:
      // a session that crashed and was then handed to another agent has had its
      // work carried forward, and the crash is that session's problem now.
      final actual = carriedForward ? SessionEnding.handedOff : ending;

      final mark = '$sessionId/${actual.name}';
      if (_considered.contains(mark)) return null;

      // Read only for the branch that needs it. A crash is a crash whatever it
      // verified, so the common path costs no verification query at all.
      final residue = actual == SessionEnding.completed
          ? verificationResidueIn(_runsFor(sessionId))
          : VerificationResidue.none;

      final reason = followUpFor(ending: actual, verification: residue);
      if (reason == null) {
        // Remembered anyway: an ending judged not worth mentioning is not worth
        // re-judging on every bump for the rest of the session list's life.
        _considered.add(mark);
        return null;
      }

      final raised = _dao.raise(
        FollowUp(
          sessionId: sessionId,
          reason: reason,
          ending: actual,
          summary: _wordsFor(sessionId, reason),
          raisedAt: _ref.read(clockProvider).nowUtc(),
        ),
      );
      _considered.add(mark);
      return raised;
    } catch (error, stack) {
      // A notice that cannot be raised must never break the thing it was
      // describing. This runs off a status stream and a revision bump; throwing
      // out of either would take a working app down over a bookkeeping row.
      _log.warning('Could not notice the end of session $sessionId.', error,
          stack);
      return null;
    }
  }

  /// The user is done with this one.
  void dismiss(FollowUp followUp) => _resolve(
    followUp,
    FollowUpResolution.dismissed,
  );

  /// The user dismissed the follow-up stored at [rowId].
  ///
  /// The inbox knows an id, not a record. Resolving straight from the id keeps
  /// the read off the dismissal path, which runs while the list is being
  /// rebuilt under the user's cursor.
  void dismissRow(int rowId) => _dao.resolve(
    rowId,
    resolution: FollowUpResolution.dismissed,
    at: _ref.read(clockProvider).nowUtc(),
  );

  /// Sessions whose work has moved to another session.
  ///
  /// Derived from the list in one pass — no query per session. Only
  /// [SessionLink.handoff] and [SessionLink.fork] count:
  /// [SessionLink.spawn] is an agent *delegating* a piece of work, which leaves
  /// the parent's own work exactly where it was.
  Set<String> _carriedForward(List<Session> sessions) => {
    for (final session in sessions)
      if (session.parentSessionId case final parent?)
        if (session.parentLink == SessionLink.handoff ||
            session.parentLink == SessionLink.fork)
          parent,
  };

  /// Closes follow-ups whose session has since been handed on or deleted.
  ///
  /// The second half of "never nag about something already handled": a session
  /// can acquire a handoff minutes after its follow-up was raised, and the
  /// notice has to leave when the work does.
  bool _retireWhatMovedOn(
    List<Session> sessions,
    Set<String> carriedForward,
  ) {
    final open = _dao.open();
    if (open.isEmpty) return false;
    final present = {for (final session in sessions) session.id};
    var retired = false;
    for (final followUp in open) {
      if (!present.contains(followUp.sessionId)) {
        _resolve(followUp, FollowUpResolution.sessionGone);
        retired = true;
      } else if (carriedForward.contains(followUp.sessionId)) {
        _resolve(followUp, FollowUpResolution.carriedForward);
        retired = true;
      }
    }
    return retired;
  }

  void _resolve(FollowUp followUp, FollowUpResolution resolution) {
    final id = followUp.id;
    if (id == null) return;
    _dao.resolve(
      id,
      resolution: resolution,
      at: _ref.read(clockProvider).nowUtc(),
    );
  }

  List<VerificationRun> _runsFor(String sessionId) =>
      _ref.read(verificationDaoProvider).listRuns(sessionId: sessionId);

  /// The source's **own words** for what was left, or null.
  ///
  /// Null is "not recorded" and is rendered as that. Nothing here composes a
  /// sentence about what the app thinks happened: a paraphrase's errors are
  /// invisible to the reader who most needs them, which is the argument
  /// `handoff_packet.dart` makes at length and it applies unchanged here.
  ///
  /// The framing around a quote *is* ours — "Last recorded decision:" — because
  /// an unlabelled sentence under "Ended in error" would read as a diagnosis of
  /// the failure, which it is not. `DecisionRecorder` frames its quotes the
  /// same way.
  String? _wordsFor(String sessionId, FollowUpReason reason) =>
      switch (reason) {
        FollowUpReason.endedInFailure => _lastDecision(sessionId),
        FollowUpReason.verificationNotPassed => _verificationWords(
          sessionId,
          wanted: (run) =>
              run.verdict != null && run.verdict != VerificationVerdict.pass,
        ),
        FollowUpReason.verificationAbandoned => _verificationWords(
          sessionId,
          wanted: (run) => run.isOpen,
        ),
        // Neither is ever raised: one is a mark the v25 migration wrote for a
        // session that had already ended, and the other is a row from a build
        // that knew more than this one. Both are read-only, and inventing words
        // for either would be inventing words.
        FollowUpReason.predatesTheFeature ||
        FollowUpReason.unrecognised => null,
      };

  /// The last thing the session wrote down before it stopped — the residue a
  /// crash leaves that is worth anything to the next reader.
  ///
  /// `forSession` returns the chain oldest first, so the last entry is the most
  /// recent. An empty record yields null rather than a sentence: nobody wrote
  /// anything down, and that is not evidence about the session.
  String? _lastDecision(String sessionId) {
    final record = _ref.read(decisionRecordDaoProvider).forSession(sessionId);
    if (record.isEmpty) return null;
    final last = record.last;
    return 'Last recorded decision — ${last.kind.label}: ${last.summary}';
  }

  /// The verification run's own title, and its own stated reason when it gave
  /// one.
  ///
  /// [wanted] is the same test the reason was chosen by, so the words and the
  /// heading above them always describe the *same run*. A session with both an
  /// abandoned run and a failed verdict is headed by the verdict, and quoting
  /// the abandoned one underneath would read as a contradiction.
  ///
  /// Newest first out of the DAO, so the first match is the one the reader
  /// last saw.
  String? _verificationWords(
    String sessionId, {
    required bool Function(VerificationRun run) wanted,
  }) {
    for (final run in _runsFor(sessionId)) {
      if (!wanted(run)) continue;
      final verdict = run.verdict?.label ?? 'No verdict';
      final reason = run.reason;
      return reason == null || reason.trim().isEmpty
          ? '$verdict — ${run.title}'
          : '$verdict — ${run.title}. ${reason.trim()}';
    }
    return null;
  }
}
