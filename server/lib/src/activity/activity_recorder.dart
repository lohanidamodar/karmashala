import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/session.dart' show SessionStatus;
import 'package:karmashala_session_engine/karmashala_session_engine.dart'
    show SessionLifecycleChange;

import 'activity_log.dart';

/// How long a wait's words may be in the log.
const int kActivityDetailLength = 120;

/// Turns the transitions the server already sees into activity drafts —
/// edges only: a status repeated is no entry.
class ActivityRecorder {
  ActivityRecorder({
    required this.record,
    required this.lastLogged,
    required this.clock,
  });

  final void Function(ActivityDraft draft) record;

  /// The newest kind logged for a session, read on first sight of it after
  /// a restart.
  final ActivityKind? Function(String sessionId) lastLogged;
  final DateTime Function() clock;

  final Map<String, AgentActivityStatus> _last = {};

  static bool _inTurn(AgentActivityStatus? s) =>
      s == AgentActivityStatus.working ||
      s == AgentActivityStatus.awaitingApproval;

  /// One status move of a watched session.
  void statusMoved(SessionStatusEntry entry) {
    final report = entry.report;
    final status = report.turnStatus;
    if (status == AgentActivityStatus.unknown) return;
    final id = entry.openId;
    final now = clock().toUtc();
    final seen = _last.containsKey(id);
    final logged = seen ? null : lastLogged(id);
    final previous = seen ? _last[id] : _fromLog(logged);
    _last[id] = status;
    if (seen && previous == status) return;
    void add(ActivityKind kind, {DateTime? at, String? detail, bool approx = false}) =>
        record(
          ActivityDraft(
            at: at ?? now,
            kind: kind,
            sessionId: id,
            detail: detail,
            approximate: approx,
          ),
        );

    final waiting = status == AgentActivityStatus.awaitingApproval;
    final wasWaiting = previous == AgentActivityStatus.awaitingApproval;
    if (_inTurn(status) && !_inTurn(previous)) {
      // Seen mid-turn with nothing logged of the session: not when it began.
      add(ActivityKind.turnStarted, approx: !seen && logged == null);
    }
    if (wasWaiting && !waiting) add(ActivityKind.waitEnded);
    if (waiting && !wasWaiting) {
      final since = report.waitingSince?.toUtc();
      add(
        ActivityKind.waitBegan,
        at: since != null && since.isBefore(now) ? since : now,
        detail: _askOf(report),
      );
    }
    if (!_inTurn(status) && _inTurn(previous)) {
      add(
        ActivityKind.turnEnded,
        detail: status == AgentActivityStatus.failed
            ? _short('failed${report.failureReason == null ? '' : ': ${report.failureReason}'}')
            : null,
        // A turn the log left open is only seen ended now: not when it was.
        approx: !seen,
      );
    }
  }

  /// What the log last said of [id], as a status: an open turn or not.
  static AgentActivityStatus? _fromLog(ActivityKind? kind) => switch (kind) {
    ActivityKind.turnStarted ||
    ActivityKind.waitEnded => AgentActivityStatus.working,
    ActivityKind.waitBegan => AgentActivityStatus.awaitingApproval,
    _ => null,
  };

  static String? _askOf(AgentStatusReport report) {
    final ask = report.toolAsk;
    if (ask != null) {
      final target = [
        'file_path',
        'path',
        'command',
        'url',
      ].map((k) => ask.input[k]).whereType<String>().firstOrNull;
      return _short(target == null ? ask.toolName : '${ask.toolName} $target');
    }
    final said = report.evidence
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .firstOrNull;
    return said == null ? null : _short(said);
  }

  static String _short(String text) {
    final line = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return line.length <= kActivityDetailLength
        ? line
        : '${line.substring(0, kActivityDetailLength - 1)}…';
  }

  /// A session row's lifecycle moved: an end is logged.
  void lifecycleChanged(SessionLifecycleChange change) {
    final ended = switch (change.to) {
      SessionStatus.completed ||
      SessionStatus.failed ||
      SessionStatus.cancelled => true,
      _ => false,
    };
    if (!ended || change.from == change.to) return;
    record(
      ActivityDraft(
        at: clock().toUtc(),
        kind: ActivityKind.sessionEnded,
        sessionId: change.sessionId,
        detail: change.to.name,
      ),
    );
  }

  /// Session [sessionId] hit a usage limit ([detail] says until when).
  void usageLimitHit(String sessionId, String detail) => record(
    ActivityDraft(
      at: clock().toUtc(),
      kind: ActivityKind.limitPaused,
      sessionId: sessionId,
      detail: _short(detail),
    ),
  );

  /// Session [sessionId] was resumed after its limit.
  void usageLimitResumed(String sessionId) => record(
    ActivityDraft(
      at: clock().toUtc(),
      kind: ActivityKind.limitResumed,
      sessionId: sessionId,
    ),
  );
}
