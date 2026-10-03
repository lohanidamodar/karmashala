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
  });

  final ChildTurnState state;
  final SessionBlock? block;
  final int? exitCode;
  final bool exitCodeKnown;
}

/// **Waits for a session's first turn to settle** — the wait behind
/// `subagent_run`. Unlike `session_wait` it is not satisfied by a session that
/// is merely ready for input: one that has not started its turn yet looks the
/// same. It settles once the agent has worked and stopped, or has an answer
/// recorded since [firstTurn]'s `since`; on a prompt or question it is
/// blocked; on the process ending, ended; at the bound, still running.
class ChildTurnWait {
  ChildTurnWait({
    required this.waits,
    required this.answerOf,
    WaitDeadline? deadline,
    this.recheck = const Duration(seconds: 2),
  }) : _deadline = deadline ?? ((bound) => Future<void>.delayed(bound));

  final HostedSessionWait waits;
  final AnswerOf answerOf;

  /// How often an agent that never reported working is looked at again, for
  /// one whose status never moves or that finished before the wait began.
  final Duration recheck;
  final WaitDeadline _deadline;

  Future<ChildTurnOutcome> firstTurn(
    String sessionId, {
    required Duration bound,
    required DateTime since,
  }) async {
    final status = waits.status;
    final running = status.liveScreenOf(sessionId);
    if (running == null) return _ended(sessionId);

    final settled = Completer<ChildTurnOutcome>();
    void settle(ChildTurnOutcome outcome) {
      if (!settled.isCompleted) settled.complete(outcome);
    }

    var worked = false;
    Future<void> consider(AgentStatusReport? report) async {
      if (settled.isCompleted) return;
      if (status.liveScreenOf(sessionId) == null) {
        settle(_ended(sessionId));
        return;
      }
      if (waits.blockedOn(sessionId) case final block?) {
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

    final changes = status.changes
        .where((moved) => moved.sessionId == sessionId)
        .listen((moved) => unawaited(consider(moved.report)));
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
          ),
        );
      }),
    );
    unawaited(
      _deadline(bound).then((_) {
        settle(const ChildTurnOutcome(ChildTurnState.running));
      }),
    );
    unawaited(consider(status.statusOf(sessionId)?.report));
    try {
      return await settled.future;
    } finally {
      again.cancel();
      await changes.cancel();
    }
  }

  ChildTurnOutcome _ended(String sessionId) {
    final ended = waits.ended(sessionId, null, null);
    return ChildTurnOutcome(
      ChildTurnState.ended,
      exitCode: ended.exitCode,
      exitCodeKnown: ended.exitCodeKnown,
    );
  }
}
