import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../../core/util/clock_provider.dart';
import '../../sessions/application/session_providers.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/lineage.dart';
import '../../verification/application/verification_providers.dart';
import 'package:karmashala_verification/verification.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import '../../sessions/data/sessions_data.dart';

/// The only thing that raises and retires follow-ups. It may read the workspace
/// and write follow-ups through the server — **it holds no path to anything
/// that starts a process**. The server keeps one open per session; this
/// decides which endings are worth one.
class FollowUpService {
  FollowUpService(this._ref);

  final Ref _ref;
  final _log = AppLogger.named('followups');

  /// `'<sessionId>/<ending>'` for every ending that has **ever** produced a
  /// follow-up. Resolved rows included, or a dismissed one is re-raised at once.
  late final Set<String> _considered = _followUps.raisedEndings();

  FollowUpsData get _followUps => _ref.read(followUpsDataProvider);

  /// One pass over the workspace the caller has already read, so raise and retire
  /// see the same list. Returns whether anything actually changed.
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

  /// A session ended. Raise a follow-up if the rule says one is owed — the
  /// server's answer, null when that session already has one open; null, with
  /// nothing sent, in the ordinary case. [carriedForward] is passed in because
  /// [sweep] knows it.
  Future<FollowUp?>? notice({
    required String sessionId,
    required SessionEnding ending,
    bool carriedForward = false,
    Session? session,
  }) {
    try {
      final row = session ?? _ref.read(sessionsDataProvider).getById(sessionId);
      // The same silence every other action in this app gives for a session
      // that no longer resolves. Never an exception, and never a launch.
      if (row == null) return null;

      // A handoff *is* the follow-up, already taken, and it outranks the row's own
      // status: a crash that was then handed on is the other session's problem.
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

      final raised = _followUps.raise(
        FollowUp(
          sessionId: sessionId,
          reason: reason,
          ending: actual,
          summary: _wordsFor(sessionId, reason),
          raisedAt: _ref.read(clockProvider).nowUtc(),
        ),
      );
      _considered.add(mark);
      return raised.catchError((Object error) {
        _log.warning('Could not raise a follow-up for $sessionId.', error);
        return null;
      });
    } catch (error, stack) {
      // A notice that cannot be raised must never break the thing it was
      // describing. This runs off a status stream and a revision bump; throwing
      // out of either would take a working app down over a bookkeeping row.
      _log.warning(
        'Could not notice the end of session $sessionId.',
        error,
        stack,
      );
      return null;
    }
  }

  /// The user is done with this one.
  void dismiss(FollowUp followUp) =>
      _resolve(followUp, FollowUpResolution.dismissed);

  /// The user dismissed the follow-up stored at [rowId]. Resolving straight from
  /// the id keeps the read off the path that runs under the user's cursor.
  void dismissRow(int rowId) => _followUps.resolve(
    rowId,
    FollowUpResolution.dismissed,
    at: _ref.read(clockProvider).nowUtc(),
  );

  /// Sessions whose work has moved to another session, in one pass. Only handoff
  /// and fork count: a spawn leaves the parent's own work where it was.
  Set<String> _carriedForward(List<Session> sessions) => {
    for (final session in sessions)
      if (session.parentSessionId case final parent?)
        if (session.parentLink == SessionLink.handoff ||
            session.parentLink == SessionLink.fork)
          parent,
  };

  /// Closes follow-ups whose session has since been handed on or deleted — the
  /// notice has to leave when the work does.
  bool _retireWhatMovedOn(List<Session> sessions, Set<String> carriedForward) {
    final open = _followUps.open();
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
    _followUps.resolve(id, resolution, at: _ref.read(clockProvider).nowUtc());
  }

  List<VerificationRun> _runsFor(String sessionId) =>
      _ref.read(verificationDaoProvider).listRuns(sessionId: sessionId);

  /// The source's **own words** for what was left, or null, which renders as
  /// "not recorded". The framing around a quote is ours; the sentence never is.
  String? _wordsFor(
    String sessionId,
    FollowUpReason reason,
  ) => switch (reason) {
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
    // Neither is ever raised: one is the v25 migration's mark, the other a row
    // from a build that knew more. Inventing words for either invents words.
    FollowUpReason.predatesTheFeature || FollowUpReason.unrecognised => null,
  };

  /// The last thing the session wrote down before it stopped. An empty record
  /// yields null: nobody wrote anything, which is not evidence about the session.
  String? _lastDecision(String sessionId) {
    final record = _ref.read(sessionRecordsProvider).decisionsFor(sessionId);
    if (record.isEmpty) return null;
    final last = record.last;
    return 'Last recorded decision — ${last.kind.label}: ${last.summary}';
  }

  /// The verification run's own title and stated reason. [wanted] is the same
  /// test the reason was chosen by, so words and heading describe one run.
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
