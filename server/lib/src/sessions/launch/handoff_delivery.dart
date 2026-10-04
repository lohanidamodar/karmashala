import 'dart:async';

import 'package:agent_cli/descriptors.dart' show AgentActivityStatus;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show DataRefused, DataRefusalCode;

import '../../status/daemon_agent_status.dart';
import '../../status/turn_settlement.dart';
import '../session_queue.dart';
import 'session_handoffs.dart';

/// **What becomes of a launch's handoff once its agent runs.** An opening
/// that waits to be typed is typed when the composer has been ready for a
/// moment, with the session's queue held until the turn it starts is seen —
/// so nothing a person sent meanwhile goes first. A file is deleted once the
/// agent has it: a system prompt when the first turn starts (the agent read
/// it at launch), an opening when that turn ends (it was read during it).
/// A session that ends first keeps nothing.
class HandoffDelivery {
  HandoffDelivery({
    required this.handoffs,
    required this.holds,
    required this.ready,
    required this.working,
    required this.deliver,
    this.hold,
    this.release,
    this.log,
    this.poll = const Duration(milliseconds: 500),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Over the server's own status and turns, typing through [deliver] (the
  /// input's immediate send) and holding [queue].
  factory HandoffDelivery.forServer({
    required SessionHandoffs handoffs,
    required DaemonAgentStatus status,
    required TurnSettlement turns,
    required Future<void> Function(String sessionId, String text) deliver,
    SessionQueue? queue,
    void Function(String message)? log,
  }) {
    AgentActivityStatus? activity(String id) =>
        status.statusOf(id)?.report.status;
    return HandoffDelivery(
      handoffs: handoffs,
      holds: status.holds,
      ready: (id) {
        final report = status.statusOf(id)?.report;
        if (report != null &&
            (report.hasOpenPrompt || report.hasOpenQuestion)) {
          return false;
        }
        return switch (report?.status) {
          AgentActivityStatus.idle => true,
          AgentActivityStatus.unknown || null => turns.quiet(id),
          _ => false,
        };
      },
      working: (id) =>
          activity(id) == AgentActivityStatus.working ||
          activity(id) == AgentActivityStatus.awaitingApproval,
      deliver: deliver,
      hold: queue?.hold,
      release: queue?.release,
      log: log,
    );
  }

  final SessionHandoffs handoffs;

  /// Whether the server holds a live screen of the session.
  final bool Function(String sessionId) holds;

  /// Whether the session's composer is idle and nothing is asked of it.
  final bool Function(String sessionId) ready;

  /// Whether the session's agent is mid-turn.
  final bool Function(String sessionId) working;

  /// Types [text] into the session and sends it; throws [DataRefused].
  final Future<void> Function(String sessionId, String text) deliver;

  /// Holds and lets go of the session's queue.
  final void Function(String sessionId)? hold;
  final void Function(String sessionId)? release;
  final void Function(String message)? log;
  final Duration poll;
  final DateTime Function() _now;

  /// How long a session may take to be seen running before it is given up.
  static const startPatience = Duration(minutes: 2);

  /// How long ready must last before the opening is typed: a TUI drawing
  /// its first screen reads as idle before its composer takes keys.
  static const settle = Duration(milliseconds: 800);

  /// How long the queue stays held for a turn the typed opening should start.
  static const turnStartGrace = Duration(seconds: 10);

  final _watched = <String, _Watch>{};
  Timer? _timer;

  /// Takes up every row a stopped server left waiting.
  void start({bool timer = true}) {
    final waiting = {
      for (final row in handoffs.dao.pending())
        if (row.route == HandoffRoute.typed || row.route == HandoffRoute.file)
          row.sessionId,
    };
    waiting.forEach(watch);
    if (timer) _timer ??= Timer.periodic(poll, (_) => unawaited(tick()));
  }

  Future<void> close() async {
    _timer?.cancel();
    _timer = null;
    for (final id in _watched.keys.toList()) {
      _drop(id);
    }
  }

  /// Follows [sessionId], whose launch left a row to use.
  void watch(String sessionId) {
    if (_watched.containsKey(sessionId)) return;
    final typed = handoffs.pendingTyped(sessionId) != null;
    if (!typed && handoffs.pendingFiles(sessionId).isEmpty) return;
    _watched[sessionId] = _Watch(_now(), holdsQueue: typed);
    if (typed) hold?.call(sessionId);
  }

  /// One look at every watched session.
  Future<void> tick() async {
    for (final id in _watched.keys.toList()) {
      await _step(id);
    }
  }

  Future<void> _step(String id) async {
    final watch = _watched[id];
    if (watch == null || watch.busy) return;
    final now = _now();
    if (!holds(id)) {
      if (watch.seen) {
        log?.call('handoff $id: the session ended before its handoff was used');
        handoffs.consume(id);
        return _drop(id);
      }
      if (now.difference(watch.since) > startPatience) {
        log?.call('handoff $id: never seen running; left to the sweep');
        return _drop(id);
      }
      return;
    }
    watch.seen = true;
    final isWorking = working(id);
    if (isWorking) watch.sawWorking = true;

    for (final row in handoffs.pendingFiles(id)) {
      final used = row.kind == HandoffKind.systemPrompt
          ? watch.sawWorking
          : watch.sawWorking && !isWorking && ready(id);
      if (used) handoffs.consume(id, kind: row.kind);
    }

    final typed = handoffs.pendingTyped(id);
    if (typed != null) {
      await _type(id, watch, typed, now);
    } else if (watch.typedAt != null && watch.holdsQueue) {
      if (isWorking || now.difference(watch.typedAt!) > turnStartGrace) {
        watch.holdsQueue = false;
        release?.call(id);
      }
    }
    if (handoffs.pendingTyped(id) == null &&
        handoffs.pendingFiles(id).isEmpty &&
        !watch.holdsQueue) {
      _watched.remove(id);
    }
  }

  Future<void> _type(
    String id,
    _Watch watch,
    SessionHandoff row,
    DateTime now,
  ) async {
    if (!ready(id) || working(id)) {
      watch.readySince = null;
      return;
    }
    final since = watch.readySince ??= now;
    if (now.difference(since) < settle) return;
    watch.busy = true;
    try {
      await deliver(id, row.text);
      handoffs.consume(id, kind: row.kind);
      watch.typedAt = _now();
      watch.sawWorking = false;
      log?.call('handoff $id: the opening message was typed in');
    } on DataRefused catch (refusal) {
      watch.readySince = null;
      if (refusal.code != DataRefusalCode.conflict &&
          refusal.code != DataRefusalCode.notFound) {
        log?.call('handoff $id: not typed: ${refusal.message}');
      }
    } on Object catch (error) {
      watch.readySince = null;
      log?.call('handoff $id: not typed: $error');
    } finally {
      watch.busy = false;
    }
  }

  void _drop(String id) {
    final watch = _watched.remove(id);
    if (watch != null && watch.holdsQueue) release?.call(id);
  }
}

class _Watch {
  _Watch(this.since, {required this.holdsQueue});

  final DateTime since;
  bool holdsQueue;
  bool seen = false;
  bool sawWorking = false;
  bool busy = false;
  DateTime? readySince;
  DateTime? typedAt;
}
