import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_notifications/evidence.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart'
    show hostSessionIdOf;

import 'package:karmashala_host_protocol/protocol.dart';
import 'daemon_agent_status.dart';

/// How a wait's bound is served; a test bounds a wait by an event it emits.
typedef WaitDeadline = Future<void> Function(Duration bound);

/// **Block until a session this host holds settles** — `session_wait`, and
/// the wait after `session_send`, answered by the server from the status it
/// keeps and the process it runs, app or no app. The same states and words
/// as the app's own wait over its panes (`SessionWaitOutcome`).
class HostedSessionWait {
  HostedSessionWait({
    required this.status,
    DateTime Function()? clock,
    WaitDeadline? deadline,
  }) : _now = clock ?? (() => DateTime.now().toUtc()),
       _deadline = deadline ?? ((bound) => Future<void>.delayed(bound));

  final DaemonAgentStatus status;
  final DateTime Function() _now;
  final WaitDeadline _deadline;

  /// **What [sessionId] is blocked on right now**, or null: an approval
  /// prompt or a question on its screen. An agent at its own input is
  /// waiting for a message, which is what a send is — not blocked.
  SessionBlock? blockedOn(String sessionId) {
    final report = status.statusOf(sessionId)?.report;
    if (report == null) return null;
    if (report.hasOpenQuestion) {
      return SessionBlock(
        kind: 'question',
        text: evidenceLine(report.evidence),
      );
    }
    if (report.hasOpenPrompt) {
      return SessionBlock(
        kind: 'approvalPrompt',
        text: evidenceLine(report.evidence),
        options: report.toolAsk?.options ?? const [],
      );
    }
    return null;
  }

  /// Blocks until [sessionId] settles, ends, or [bound] elapses. [inputSent]
  /// is carried through so a timed-out caller knows whether its send went in.
  Future<SessionWaitOutcome> wait(
    String sessionId, {
    Duration? bound,
    bool? inputSent,
  }) async {
    final completer = Completer<SessionWaitOutcome>();
    AgentStatusReport? opening;
    var changed = false;
    var transcriptMoved = false;

    void settle(SessionWaitOutcome outcome) {
      if (!completer.isCompleted) completer.complete(outcome);
    }

    // An SSH box session is waited on too: a send types into it.
    final running = status.liveScreenOf(sessionId);
    if (running == null) {
      return ended(sessionId, status.statusOf(sessionId)?.report, inputSent);
    }

    void consider(AgentStatusReport report) {
      final before = opening;
      if (before == null) {
        opening = report;
      } else {
        // Which evidence moved matters: a hook ageing out flips `source`
        // with the agent having done nothing.
        if (report.status != before.status ||
            !_sameLines(report.evidence, before.evidence)) {
          changed = true;
        }
        if (_advanced(before.sourceModifiedAt, report.sourceModifiedAt)) {
          changed = true;
          transcriptMoved = true;
        }
      }
      if (status.liveScreenOf(sessionId) == null) {
        settle(ended(sessionId, report, inputSent, changed: changed));
        return;
      }
      if (blockedOn(sessionId) case final block?) {
        settle(
          _outcome(
            SessionWaitState.blocked,
            report,
            changed: changed,
            transcriptMoved: transcriptMoved,
            inputSent: inputSent,
            block: block,
          ),
        );
        return;
      }
      // `awaitingApproval` with no open prompt is an agent at its own input —
      // ready, not blocked. `working` and `unknown` are the two that wait.
      final ready =
          report.status == AgentActivityStatus.idle ||
          report.status == AgentActivityStatus.failed ||
          report.status == AgentActivityStatus.awaitingApproval;
      if (!ready) return;
      settle(
        _outcome(
          changed ? SessionWaitState.done : SessionWaitState.idle,
          report,
          changed: changed,
          transcriptMoved: transcriptMoved,
          inputSent: inputSent,
        ),
      );
    }

    final statuses = status.changes
        .where((moved) => moved.sessionId == sessionId)
        .listen((moved) => consider(moved.report));
    if (status.statusOf(sessionId)?.report case final now?) consider(now);
    // Only a process that stopped *by itself* — or was ended — reaches here.
    unawaited(
      running.ended.then((end) {
        settle(
          _outcome(
            SessionWaitState.ended,
            opening,
            changed: changed,
            transcriptMoved: transcriptMoved,
            inputSent: inputSent,
            exitCode: end.exitCode,
            // Null is a real answer here, and the one thing it must never
            // become is a zero: a process whose code we never learned did not
            // succeed.
            exitCodeKnown: end.exitCode != null,
          ),
        );
      }),
    );
    unawaited(
      _deadline(bound ?? kSessionWaitDefaultBound).then((_) {
        settle(
          _outcome(
            SessionWaitState.timeout,
            opening,
            changed: changed,
            transcriptMoved: transcriptMoved,
            inputSent: inputSent,
          ),
        );
      }),
    );
    try {
      return await completer.future;
    } finally {
      await statuses.cancel();
    }
  }

  /// The answer for a session with nothing running in it here. The exit code
  /// is the one this host collected, when it still remembers the session.
  SessionWaitOutcome ended(
    String sessionId,
    AgentStatusReport? report,
    bool? inputSent, {
    bool changed = false,
  }) {
    final session = status.registry.findProcess(hostSessionIdOf(sessionId));
    final lifecycle = session?.lifecycle;
    final code = lifecycle is SessionExited ? lifecycle.exitCode : null;
    return _outcome(
      SessionWaitState.ended,
      report,
      changed: changed,
      transcriptMoved: false,
      inputSent: inputSent,
      exitCode: code,
      exitCodeKnown: code != null,
    );
  }

  SessionWaitOutcome _outcome(
    SessionWaitState state,
    AgentStatusReport? report, {
    required bool changed,
    required bool transcriptMoved,
    required bool? inputSent,
    SessionBlock? block,
    int? exitCode,
    bool exitCodeKnown = false,
  }) {
    final since = report?.evidenceAt;
    return SessionWaitOutcome(
      state: state,
      agentStatus: report?.status ?? AgentActivityStatus.unknown,
      source: report?.source ?? AgentStatusSource.none,
      since: since,
      // How old the evidence is *now*, not when we happened to see it.
      evidenceAge: since == null ? null : _now().difference(since),
      changed: changed,
      transcriptChanged: transcriptMoved
          ? true
          : (report?.sourceModifiedAt == null ? null : false),
      blockedOn: block,
      exitCode: exitCode,
      exitCodeKnown: exitCodeKnown,
      inputSent: inputSent,
    );
  }

  static bool _advanced(DateTime? before, DateTime? after) =>
      after != null && (before == null || after.isAfter(before));

  static bool _sameLines(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
