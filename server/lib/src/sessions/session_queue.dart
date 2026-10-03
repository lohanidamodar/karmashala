import 'dart:async';

import 'package:agent_cli/descriptors.dart' show AgentActivityStatus;
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart' show SessionQueueDao;

import '../domain/uuid.dart';
import '../status/daemon_agent_status.dart';
import '../status/turn_settlement.dart';

/// What [SessionQueue.admit] decided for one message.
sealed class QueueAdmission {
  const QueueAdmission();
}

/// Deliver it now. The session is held busy until the caller reports the
/// delivery with [SessionQueue.afterImmediate].
final class AdmitNow extends QueueAdmission {
  const AdmitNow();
}

/// It waits at the server as [message], [position] among the session's
/// waiting messages (from 1).
final class AdmitQueued extends QueueAdmission {
  const AdmitQueued(this.message, this.position);

  final QueuedMessage message;
  final int position;
}

/// **Every message sent to a session goes through here**: a client's
/// `sessions.send`, an agent's `session_send`, a phone on the older API.
/// While the session's turn runs — or earlier messages still wait — the
/// message is kept in `session_queued_messages`; each time a turn ends
/// ([TurnSettlement]), the head is delivered, one per turn.
///
/// A stopped ACP session is resumed to take its head ([resumesOnSend]). A
/// stopped PTY session is resumed ([resumeStopped]) when a message is queued
/// behind others, so nothing waits for a session nobody runs: with the head
/// as its opening prompt where the agent takes one, else bare and given the
/// head once idle.
class SessionQueue {
  SessionQueue({
    required this.dao,
    required this.status,
    TurnSettlement? turns,
    this.resumesOnSend,
    this.resumeStopped,
    this.takesOpeningMessage,
    this.announce,
    this.log,
    this.turnStartGrace = const Duration(seconds: 10),
    Duration quietPeriod = kTurnQuietPeriod,
    Duration quietPoll = const Duration(seconds: 1),
    DateTime Function()? now,
    String Function()? newId,
  }) : _ownsTurns = turns == null,
       turns =
           turns ??
           TurnSettlement(
             status: status,
             quietPeriod: quietPeriod,
             poll: quietPoll,
           ),
       _now = now ?? (() => DateTime.now().toUtc()),
       _newId = newId ?? newUuid;

  final SessionQueueDao dao;
  final DaemonAgentStatus status;

  /// Whether a session's turn still runs, and when it settles.
  final TurnSettlement turns;
  final bool _ownsTurns;

  /// Whether row [String] speaks ACP, so a send resumes it when nothing runs
  /// it.
  final bool Function(String sessionId)? resumesOnSend;

  /// Resumes row [String] that nothing runs, [prompt] its opening message
  /// when given — `ServerSessionLauncher.resume`.
  final Future<Object?> Function(String sessionId, String? prompt)?
  resumeStopped;

  /// Whether row [String]'s agent takes an opening message when it starts
  /// (`launch.acceptsPromptArgument`).
  final bool Function(String sessionId)? takesOpeningMessage;

  /// Told the session's open messages each time they move.
  final void Function(String sessionId, List<QueuedMessage> open)? announce;
  final void Function(String message)? log;

  /// How long a PTY session that was typed into counts as busy while its
  /// screen has not yet shown the turn start: the status is read every tick,
  /// so the next message would otherwise be typed into the same turn.
  final Duration turnStartGrace;

  /// Delivers [text] as an immediate send would — set by `SessionInput`.
  /// Throws [DataRefused] when it cannot.
  Future<void> Function(String sessionId, String text)? deliver;

  final DateTime Function() _now;
  final String Function() _newId;

  /// Sessions with a delivery in progress, immediate or drained.
  final _inFlight = <String>{};

  /// Sessions held busy by [hold]: their sends queue and nothing drains.
  final _held = <String>{};

  /// Holds [sessionId] busy while something else owns it — a switch of its
  /// agent — so a send in the meantime queues rather than races the start.
  void hold(String sessionId) => _held.add(sessionId);

  /// Lets [sessionId] go again, delivering what queued meanwhile.
  void release(String sessionId) {
    if (_held.remove(sessionId)) _kick(sessionId);
  }

  /// Sessions whose agent was seen working during the delivery in flight.
  final _sawWorking = <String>{};

  /// PTY sessions typed into and not yet seen working.
  final _awaitingTurn = <String, Timer>{};

  /// Sessions known to have a row still queued, so a status tick costs no
  /// query for the rest.
  final _withQueued = <String>{};

  /// Sessions resumed bare for their head, which waits for the turn to end.
  final _resumedForHead = <String>{};
  final _waiters = <String, List<Completer<QueuedMessage>>>{};
  final _subscriptions = <StreamSubscription<Object?>>[];
  var _closed = false;

  static const interruptedError =
      'The server stopped while this message was being delivered, so it was '
      'not sent again: the agent may already have it.';

  /// Fails what a stopped server left `delivering`, and starts following
  /// every status the server keeps.
  void start() {
    for (final sessionId in dao.failInterrupted(
      now: _now(),
      error: interruptedError,
    )) {
      log?.call('queue $sessionId: a delivery a stop interrupted is failed');
      _announce(sessionId);
    }
    _withQueued.addAll(dao.sessionsWithQueued());
    if (_subscriptions.isNotEmpty) return;
    if (_ownsTurns) turns.start();
    _subscriptions
      ..add(status.changes.listen(_onStatus))
      ..add(
        turns.settled.listen((sessionId) {
          if (_withQueued.contains(sessionId)) _kick(sessionId);
        }),
      );
  }

  Future<void> close() async {
    _closed = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    for (final timer in _awaitingTurn.values) {
      timer.cancel();
    }
    _awaitingTurn.clear();
    if (_ownsTurns) await turns.close();
  }

  /// Whether [sessionId]'s agent is mid-turn, or a message is on its way.
  bool busy(String sessionId) {
    if (_inFlight.contains(sessionId) || _held.contains(sessionId)) {
      return true;
    }
    if (status.acpRuntimeOf(sessionId) == null &&
        _awaitingTurn.containsKey(sessionId)) {
      return true;
    }
    return turns.running(sessionId);
  }

  /// Queues [text] when [sessionId] is busy or has messages waiting;
  /// otherwise claims the session for an immediate delivery. A [requestId]
  /// already queued answers its row again.
  QueueAdmission admit(
    String sessionId,
    String text, {
    required QueuedMessageOrigin origin,
    String? originId,
    String? requestId,
  }) {
    final queued = queueIfBusy(
      sessionId,
      text,
      origin: origin,
      originId: originId,
      requestId: requestId,
    );
    if (queued != null) return queued;
    _inFlight.add(sessionId);
    _sawWorking.remove(sessionId);
    return const AdmitNow();
  }

  /// [admit] for a caller that delivers by its own means: null means "send
  /// it now", and nothing is claimed.
  AdmitQueued? queueIfBusy(
    String sessionId,
    String text, {
    required QueuedMessageOrigin origin,
    String? originId,
    String? requestId,
  }) {
    if (requestId != null && requestId.isNotEmpty) {
      final existing = dao.byRequest(sessionId, requestId);
      if (existing != null) {
        return AdmitQueued(existing, dao.positionOf(sessionId, existing.seq));
      }
    }
    if (!busy(sessionId) && !dao.hasWaiting(sessionId)) return null;
    final message = dao.enqueue(
      id: _newId(),
      sessionId: sessionId,
      text: text,
      origin: origin,
      originId: originId,
      requestId: requestId,
      now: _now(),
    );
    _withQueued.add(sessionId);
    log?.call('queue $sessionId: ${message.id} queued behind the running turn');
    _announce(sessionId);
    // Nothing may be running to end a turn: a stopped session is resumed.
    _kick(sessionId, resume: true);
    return AdmitQueued(message, dao.positionOf(sessionId, message.seq));
  }

  /// Reports the immediate delivery [admit] allowed.
  void afterImmediate(String sessionId, {required bool delivered}) {
    _inFlight.remove(sessionId);
    if (delivered) _awaitTurnStart(sessionId);
    _kick(sessionId);
  }

  /// The messages [sessionId] holds, queued, delivering or failed, in order.
  List<QueuedMessage> list(String sessionId) => dao.open(sessionId);

  /// Replaces queued message [id]'s text; refused once it is on its way.
  QueuedMessage edit(String sessionId, String id, String text) {
    if (text.trim().isEmpty) {
      throw const DataRefused.invalid('there is no message to send');
    }
    final message = _own(sessionId, id);
    if (!dao.editText(id, text, now: _now())) {
      throw DataRefused(
        DataRefusalCode.conflict,
        'this message is already ${_words(message.state)}, so it can no '
        'longer be edited',
      );
    }
    _announce(sessionId);
    return dao.getById(id)!;
  }

  /// Cancels queued message [id], or dismisses a failed one.
  QueuedMessage cancel(String sessionId, String id) {
    final message = _own(sessionId, id);
    final from = message.state;
    final movable =
        from == QueuedMessageState.queued || from == QueuedMessageState.failed;
    if (!movable ||
        !dao.transition(
          id,
          from: from,
          to: QueuedMessageState.cancelled,
          now: _now(),
        )) {
      throw DataRefused(
        DataRefusalCode.conflict,
        'this message is already ${_words(message.state)}, so it can no '
        'longer be cancelled',
      );
    }
    final cancelled = dao.getById(id)!;
    _settle(cancelled);
    _announce(sessionId);
    _kick(sessionId);
    return cancelled;
  }

  /// Completes when message [id] is delivered, failed or cancelled.
  Future<QueuedMessage> settled(String id) {
    final now = dao.getById(id);
    if (now != null &&
        now.state != QueuedMessageState.queued &&
        now.state != QueuedMessageState.delivering) {
      return Future.value(now);
    }
    final waiter = Completer<QueuedMessage>();
    (_waiters[id] ??= []).add(waiter);
    return waiter.future;
  }

  QueuedMessage _own(String sessionId, String id) {
    final message = dao.getById(id);
    if (message == null || message.sessionId != sessionId) {
      throw const DataRefused.notFound('this session holds no such message');
    }
    return message;
  }

  static String _words(QueuedMessageState state) => switch (state) {
    QueuedMessageState.queued => 'queued',
    QueuedMessageState.delivering => 'being delivered',
    QueuedMessageState.delivered => 'delivered',
    QueuedMessageState.cancelled => 'cancelled',
    QueuedMessageState.failed => 'failed',
  };

  static bool _working(AgentActivityStatus? status) =>
      status == AgentActivityStatus.working ||
      status == AgentActivityStatus.awaitingApproval;

  void _onStatus(HostedAgentStatus change) {
    final sessionId = change.sessionId;
    final kind = change.report.status;
    if (_working(kind)) {
      if (_inFlight.contains(sessionId)) _sawWorking.add(sessionId);
      _awaitingTurn.remove(sessionId)?.cancel();
      return;
    }
    if (_withQueued.contains(sessionId)) _kick(sessionId);
  }

  void _awaitTurnStart(String sessionId) {
    if (_sawWorking.remove(sessionId)) return;
    if (status.acpRuntimeOf(sessionId) != null) return;
    _awaitingTurn.remove(sessionId)?.cancel();
    _awaitingTurn[sessionId] = Timer(turnStartGrace, () {
      _awaitingTurn.remove(sessionId);
      _kick(sessionId);
    });
  }

  /// Whether [sessionId] can take its head now.
  bool _ready(String sessionId) {
    if (_inFlight.contains(sessionId) || _held.contains(sessionId)) {
      return false;
    }
    final runtime = status.acpRuntimeOf(sessionId);
    if (runtime != null) return !runtime.inTurn;
    if (_awaitingTurn.containsKey(sessionId)) return false;
    if (resumesOnSend?.call(sessionId) ?? false) return true;
    if (!status.holds(sessionId)) return false;
    final report = status.statusOf(sessionId)?.report;
    if (report != null && (report.hasOpenPrompt || report.hasOpenQuestion)) {
      return false;
    }
    // Only a real end of turn: idle or failed, or a reader that cannot tell
    // over a screen that has stopped moving.
    return switch (report?.status) {
      AgentActivityStatus.idle || AgentActivityStatus.failed => true,
      AgentActivityStatus.working ||
      AgentActivityStatus.awaitingApproval => false,
      AgentActivityStatus.unknown || null => turns.quiet(sessionId),
    };
  }

  /// Whether nothing runs [sessionId] and [resumeStopped] would start it.
  bool _stopped(String sessionId) =>
      resumeStopped != null &&
      !_inFlight.contains(sessionId) &&
      !_held.contains(sessionId) &&
      !_resumedForHead.contains(sessionId) &&
      status.acpRuntimeOf(sessionId) == null &&
      !(resumesOnSend?.call(sessionId) ?? false) &&
      !status.holds(sessionId);

  // Deferred: a turn's end is published from inside the runtime that ended
  // it, which must finish settling before the next turn opens. Only a new
  // message [resume]s a stopped session: one a person ended stays ended.
  void _kick(String sessionId, {bool resume = false}) {
    if (_closed) return;
    scheduleMicrotask(() => unawaited(_drain(sessionId, resume: resume)));
  }

  Future<void> _drain(String sessionId, {bool resume = false}) async {
    final deliver = this.deliver;
    if (_closed || deliver == null) return;
    if (resume && _stopped(sessionId)) return _resumeFor(sessionId);
    if (!_ready(sessionId)) return;
    final head = dao.head(sessionId);
    if (head == null) {
      _withQueued.remove(sessionId);
      return;
    }
    if (!dao.transition(
      head.id,
      from: QueuedMessageState.queued,
      to: QueuedMessageState.delivering,
      now: _now(),
    )) {
      return;
    }
    _inFlight.add(sessionId);
    _sawWorking.remove(sessionId);
    _resumedForHead.remove(sessionId);
    _announce(sessionId);
    var delivered = false;
    try {
      await deliver(sessionId, head.text);
      delivered = true;
      _finish(head, QueuedMessageState.delivered);
      log?.call('queue $sessionId: ${head.id} delivered');
    } on DataRefused catch (refusal) {
      if (refusal.code == DataRefusalCode.notFound ||
          refusal.code == DataRefusalCode.conflict) {
        // Nothing was typed: it waits for the next turn's end.
        dao.transition(
          head.id,
          from: QueuedMessageState.delivering,
          to: QueuedMessageState.queued,
          now: _now(),
        );
        log?.call('queue $sessionId: ${head.id} held: ${refusal.message}');
      } else {
        _finish(head, QueuedMessageState.failed, error: refusal.message);
      }
    } on Object catch (error) {
      _finish(head, QueuedMessageState.failed, error: '$error');
    } finally {
      _inFlight.remove(sessionId);
      if (delivered) _awaitTurnStart(sessionId);
      if (dao.head(sessionId) == null) _withQueued.remove(sessionId);
      _announce(sessionId);
    }
    if (delivered) _kick(sessionId);
  }

  /// Starts [sessionId], which nothing runs, for its head: as the opening
  /// prompt where its agent takes one, else bare, the head then delivered at
  /// the idle composer. A refused resume fails the head in its words.
  Future<void> _resumeFor(String sessionId) async {
    final resume = resumeStopped!;
    final head = dao.head(sessionId);
    if (head == null) return;
    final withPrompt = takesOpeningMessage?.call(sessionId) ?? false;
    if (withPrompt &&
        !dao.transition(
          head.id,
          from: QueuedMessageState.queued,
          to: QueuedMessageState.delivering,
          now: _now(),
        )) {
      return;
    }
    _inFlight.add(sessionId);
    _sawWorking.remove(sessionId);
    log?.call(
      'queue $sessionId: nothing runs it; resuming it for ${head.id}'
      '${withPrompt ? ' as its opening prompt' : ''}',
    );
    _announce(sessionId);
    var delivered = false;
    try {
      await resume(sessionId, withPrompt ? head.text : null);
      if (withPrompt) {
        delivered = true;
        _finish(head, QueuedMessageState.delivered);
      } else {
        _resumedForHead.add(sessionId);
      }
    } on Object catch (error) {
      final words = switch (error) {
        DataRefused(:final message) => message,
        StateError(:final message) => message,
        ArgumentError(:final message) => '$message',
        _ => '$error',
      };
      if (!withPrompt) {
        dao.transition(
          head.id,
          from: QueuedMessageState.queued,
          to: QueuedMessageState.delivering,
          now: _now(),
        );
      }
      _finish(
        head,
        QueuedMessageState.failed,
        error:
            'This session is not running and could not be resumed to take '
            'the message, so it was not sent: $words',
      );
    } finally {
      _inFlight.remove(sessionId);
      if (delivered) _awaitTurnStart(sessionId);
      _announce(sessionId);
    }
    // A bare resume's idle screen may already be read.
    if (!delivered) _kick(sessionId);
  }

  void _finish(QueuedMessage head, QueuedMessageState to, {String? error}) {
    dao.transition(
      head.id,
      from: QueuedMessageState.delivering,
      to: to,
      now: _now(),
      error: error,
    );
    if (to == QueuedMessageState.failed) {
      log?.call('queue ${head.sessionId}: ${head.id} failed: $error');
    }
    final row = dao.getById(head.id);
    if (row != null) _settle(row);
  }

  void _settle(QueuedMessage message) {
    for (final waiter in _waiters.remove(message.id) ?? const []) {
      if (!waiter.isCompleted) waiter.complete(message);
    }
  }

  void _announce(String sessionId) =>
      announce?.call(sessionId, dao.open(sessionId));
}
