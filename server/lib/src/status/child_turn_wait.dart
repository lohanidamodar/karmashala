import 'dart:async';

import 'package:agent_cli/descriptors.dart'
    show AgentActivityStatus, AgentStatusReport;
import 'package:karmashala_agent_status/karmashala_agent_status.dart'
    show SessionBlock;

import 'hosted_session_wait.dart';

/// The most of an agent's last answer a wait returns.
const int kFinalAnswerMaxChars = 20000;

/// What an agent said last, and when; null when it has said nothing yet.
typedef AnswerOf =
    Future<({String text, DateTime? at})?> Function(
      String sessionId, {
      DateTime? since,
    });

/// Where a session's first turn got to.
enum ChildTurnState { done, failed, blocked, ended, running }

class ChildTurnOutcome {
  const ChildTurnOutcome(
    this.state, {
    this.block,
    this.exitCode,
    this.exitCodeKnown = false,
    this.idle = false,
    this.inBackground = false,
  });

  final ChildTurnState state;
  final SessionBlock? block;
  final int? exitCode;
  final bool exitCodeKnown;

  /// Ended without a turn: [ChildTurnWait.nextTurn] saw no work before it.
  final bool idle;

  /// Settled by [ChildTurnWait.backgroundCap]: the agent's own turn ended
  /// and only background work it started has run since, with nothing new.
  final bool inBackground;
}

/// How long a session whose own turn ended may sit on background work it
/// started, with nothing new said, before its wait settles anyway.
const Duration kBackgroundQuietCap = Duration(minutes: 30);

/// **Waits for a session's first turn to settle** — the wait behind
/// `subagent_run`. Unlike `session_wait` it is not satisfied by a session that
/// is merely ready for input: one that has not started its turn yet looks the
/// same. It settles once the agent has worked and stopped, or has an answer
/// recorded since [firstTurn]'s `since`; on a prompt or question it is
/// blocked; on the process ending, ended; at the bound, still running. A turn
/// the server decides is over ([settled], `TurnSettlement`) settles it too.
class ChildTurnWait {
  ChildTurnWait({
    required this.waits,
    required this.answerOf,
    this.settled,
    WaitDeadline? deadline,
    this.recheck = const Duration(seconds: 2),
    this.backgroundCap = kBackgroundQuietCap,
  }) : _deadline = deadline ?? ((bound) => Future<void>.delayed(bound));

  /// [kBackgroundQuietCap] but in tests.
  final Duration backgroundCap;

  final HostedSessionWait waits;
  final AnswerOf answerOf;

  /// Each session whose turn settled: the one word on a turn whose reader
  /// says only working or unknown, which no status here would end.
  final Stream<String>? settled;

  /// How often an agent that never reported working is looked at again, for
  /// one whose status never moves or that finished before the wait began.
  final Duration recheck;
  final WaitDeadline _deadline;

  Future<ChildTurnOutcome> firstTurn(
    String sessionId, {
    required Duration bound,
    required DateTime since,
  }) => _turn(sessionId, bound: bound, since: since, afterWork: false);

  /// The next turn [sessionId] works, however long it sits idle first: it
  /// settles only once the agent was seen working, so a ready screen, an
  /// answer already given or a prompt still open from before settle nothing.
  Future<ChildTurnOutcome> nextTurn(
    String sessionId, {
    required DateTime since,
  }) => _turn(sessionId, bound: null, since: since, afterWork: true);

  Future<ChildTurnOutcome> _turn(
    String sessionId, {
    required Duration? bound,
    required DateTime since,
    required bool afterWork,
  }) async {
    final status = waits.status;
    final running = status.liveScreenOf(sessionId);
    if (running == null) return _ended(sessionId, idle: afterWork);

    final settled = Completer<ChildTurnOutcome>();
    void settle(ChildTurnOutcome outcome) {
      if (!settled.isCompleted) settled.complete(outcome);
    }

    var worked = false;
    Future<void> consider(AgentStatusReport? report) async {
      if (settled.isCompleted) return;
      if (status.liveScreenOf(sessionId) == null) {
        settle(_ended(sessionId, idle: afterWork && !worked));
        return;
      }
      if (waits.blockedOn(sessionId) case final block?
          when !afterWork || worked) {
        settle(ChildTurnOutcome(ChildTurnState.blocked, block: block));
        return;
      }
      if (report == null) return;
      if (report.status == AgentActivityStatus.working) {
        worked = true;
        return;
      }
      final ready =
          report.status == AgentActivityStatus.idle ||
          report.status == AgentActivityStatus.failed ||
          report.status == AgentActivityStatus.awaitingApproval;
      if (!ready) return;
      if (!worked && afterWork) return;
      // Ready and never seen working is also a session not yet started:
      // only an answer recorded since the launch tells them apart.
      if (!worked && await answerOf(sessionId, since: since) == null) return;
      settle(
        ChildTurnOutcome(
          report.status == AgentActivityStatus.failed
              ? ChildTurnState.failed
              : ChildTurnState.done,
        ),
      );
    }

    // A turn handed off to background work that never ends still settles,
    // once nothing new has been said for [backgroundCap]. Armed only by a
    // move, so the wait after that settling is not settled again by it.
    Timer? quietBackground;
    void watchBackground(AgentStatusReport? report) {
      quietBackground?.cancel();
      quietBackground = report != null && report.backgroundOnly
          ? Timer(backgroundCap, () {
              settle(
                const ChildTurnOutcome(ChildTurnState.done, inBackground: true),
              );
            })
          : null;
    }

    final changes = status.changes
        .where((moved) => moved.sessionId == sessionId)
        .listen((moved) {
          watchBackground(moved.report);
          unawaited(consider(moved.report));
        });
    // Settled over a status that says nothing (unknown) is the quiet screen
    // of a turn seen working; any other status is read as it says. Never
    // seen working, it is a turn only if an answer was recorded since the
    // launch: an opening left unsent is a still screen too (bug 13).
    final quiet = this.settled?.where((id) => id == sessionId).listen((
      _,
    ) async {
      final report = status.statusOf(sessionId)?.report;
      if (report == null || report.status == AgentActivityStatus.unknown) {
        if (afterWork && !worked) return;
        if (!worked && await answerOf(sessionId, since: since) == null) return;
        worked = true;
        if (waits.blockedOn(sessionId) == null &&
            status.liveScreenOf(sessionId) != null) {
          settle(const ChildTurnOutcome(ChildTurnState.done));
        }
        return;
      }
      unawaited(consider(report));
    });
    final again = Timer.periodic(recheck, (_) {
      unawaited(consider(status.statusOf(sessionId)?.report));
    });
    unawaited(
      running.ended.then((end) {
        settle(
          ChildTurnOutcome(
            ChildTurnState.ended,
            exitCode: end.exitCode,
            exitCodeKnown: end.exitCode != null,
            idle: afterWork && !worked,
          ),
        );
      }),
    );
    if (bound != null) {
      unawaited(
        _deadline(bound).then((_) {
          settle(const ChildTurnOutcome(ChildTurnState.running));
        }),
      );
    }
    unawaited(consider(status.statusOf(sessionId)?.report));
    try {
      return await settled.future;
    } finally {
      quietBackground?.cancel();
      again.cancel();
      await changes.cancel();
      await quiet?.cancel();
    }
  }

  ChildTurnOutcome _ended(String sessionId, {bool idle = false}) {
    final ended = waits.ended(sessionId, null, null);
    return ChildTurnOutcome(
      ChildTurnState.ended,
      exitCode: ended.exitCode,
      exitCodeKnown: ended.exitCodeKnown,
      idle: idle,
    );
  }
}
