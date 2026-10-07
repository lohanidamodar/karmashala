import 'dart:async';
import 'dart:convert';

import 'package:agent_cli/descriptors.dart' show AgentActivityStatus;
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart'
    show hostSessionIdOf;
import 'package:karmashala_session_engine/store.dart' show SessionQueueDao;

import '../automations/server_resume_runner.dart' show ResumeQueue;
import '../domain/uuid.dart';
import '../status/daemon_agent_status.dart';
import '../status/turn_settlement.dart';

/// The app-metadata key holding the sessions whose person paused their
/// queue: a JSON list of ids, so a restart keeps the pause.
const String kQueuePausedKey = 'queue_paused.v1';

/// What [SessionQueue.admit] decided for one message.
sealed class QueueAdmission {
  const QueueAdmission();
}

/// Deliver it now. The session is held busy until the caller reports the
/// delivery with [SessionQueue.afterImmediate].
final class AdmitNow extends QueueAdmission {
  const AdmitNow({this.midTurn = false});

  /// Typed into the running turn, as a person typing would: a delivery
  /// refused before anything was typed belongs in the queue instead.
  final bool midTurn;
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
/// head once idle. A session ended on purpose is never resumed for what was
/// queued before its end: that is cancelled ([ended]).
///
/// A queue can be held past the turn's end ([QueueHold]): on a usage limit
/// ([limitHold]), whose resume then delivers the head in its message's place
/// ([sendForResume]). Clients are told the hold on each queued message.
class SessionQueue implements ResumeQueue {
  SessionQueue({
    required this.dao,
    required this.status,
    TurnSettlement? turns,
    this.resumesOnSend,
    this.resumeStopped,
    this.takesOpeningMessage,
    this.takesInputMidTurn,
    this.limitHold,
    this.endedDeliberately,
    this.personTypedAt,
    this.typingGrace = const Duration(seconds: 5),
    this.readPaused,
    this.writePaused,
    this.announce,
    this.log,
    this.turnStartGrace = const Duration(seconds: 10),
    this.staleAfter = const Duration(minutes: 3),
    this.staleSweep = const Duration(seconds: 30),
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

  /// Whether row [String]'s terminal agent takes a message typed while its
  /// turn runs, and its screen can show it taken
  /// (`AgentTerminalRules.takesInputMidTurn`).
  final bool Function(String sessionId)? takesInputMidTurn;

  /// What holds row [String]'s queue on its usage limit or a scheduled
  /// resume, or null.
  final QueueHold? Function(String sessionId)? limitHold;

  /// Whether row [String] was ended on purpose (closed, `session_end`): what
  /// still waits for it at start is cancelled ([ended]).
  final bool Function(String sessionId)? endedDeliberately;

  /// When a person last typed into row [String]'s terminal, or null: a
  /// message typed then would land in their draft.
  final DateTime? Function(String sessionId)? personTypedAt;

  /// Where the paused sessions are kept (app metadata), so a restart does not
  /// turn a person's pause into a delivery.
  final String? Function()? readPaused;
  final void Function(String value)? writePaused;

  /// How long after a person's keystroke a PTY delivery waits.
  final Duration typingGrace;

  /// Told the session's open messages each time they move.
  final void Function(String sessionId, List<QueuedMessage> open)? announce;
  final void Function(String message)? log;

  /// How long a PTY session that was typed into counts as busy while its
  /// screen has not yet shown the turn start: the status is read every tick,
  /// so the next message would otherwise be typed into the same turn.
  final Duration turnStartGrace;

  /// How long a head may wait behind a session ready to take it before a
  /// sweep, every [staleSweep], logs it and delivers it: a turn's end that
  /// never woke the queue must not leave a message sitting.
  final Duration staleAfter;
  final Duration staleSweep;

  /// Delivers [text] as an immediate send would — set by `SessionInput`.
  /// Throws [DataRefused] when it cannot.
  Future<void> Function(String sessionId, String text)? deliver;

  /// A delegation row's text as it should go now, read as it is delivered:
  /// null keeps it, empty means nothing in it still holds and it is
  /// cancelled. Set by `DelegationResults`.
  String? Function(QueuedMessage head)? restate;

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

  /// The hold each session's clients were last told.
  final _toldHold = <String, QueueHold?>{};

  /// Sessions whose person stopped them or paused their queue.
  final _paused = <String>{};

  /// PTY sessions whose delivery waits on a person typing, since when.
  final _typingHolds = <String, ({DateTime since, Timer timer})>{};

  /// The longest typing holds a delivery: a pane's own replies to the
  /// agent's terminal queries must not starve the queue.
  static const typingHoldLimit = Duration(seconds: 30);
  final _subscriptions = <StreamSubscription<Object?>>[];
  Timer? _sweep;

  /// Heads already logged as stale, so a sweep says so once.
  final _staleLogged = <String>{};
  var _closed = false;

  static const interruptedError =
      'The server stopped while this message was being delivered, so it was '
      'not sent again: the agent may already have it.';

  static const endedBeforeStartReason =
      'The session had been ended before it could take this message, so it '
      'was not sent.';

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
    for (final sessionId in dao.sessionsWithQueued()) {
      if (endedDeliberately?.call(sessionId) ?? false) {
        ended(sessionId, reason: endedBeforeStartReason);
      }
    }
    _withQueued.addAll(dao.sessionsWithQueued());
    _loadPaused();
    // Each is told what holds it — a session nothing runs says so.
    refreshAll();
    if (_subscriptions.isNotEmpty) return;
    if (_ownsTurns) turns.start();
    _subscriptions
      ..add(status.changes.listen(_onStatus))
      ..add(
        turns.settled.listen((sessionId) {
          if (_withQueued.contains(sessionId)) _kick(sessionId);
        }),
      );
    _sweep = Timer.periodic(staleSweep, (_) => _sweepStale());
  }

  void _sweepStale() {
    if (_closed || deliver == null) return;
    final now = _now();
    for (final sessionId in dao.sessionsWithQueued()) {
      final head = dao.head(sessionId);
      if (head == null || head.state != QueuedMessageState.queued) continue;
      final waited = now.difference(head.createdAt);
      if (waited < staleAfter) continue;
      if (_holdOf(sessionId) != null || !_ready(sessionId)) continue;
      _withQueued.add(sessionId);
      if (_staleLogged.add(head.id)) {
        log?.call(
          'queue $sessionId: ${head.id} waited ${waited.inMinutes} min '
          'behind a session at its prompt; delivering it now',
        );
      }
      _kick(sessionId);
    }
  }

  Future<void> close() async {
    _closed = true;
    _sweep?.cancel();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    for (final hold in _typingHolds.values) {
      hold.timer.cancel();
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
  /// already queued answers its row again. [asTyping] — a person's send —
  /// goes into a running turn at once where the agent takes it there.
  QueueAdmission admit(
    String sessionId,
    String text, {
    required QueuedMessageOrigin origin,
    String? originId,
    String? requestId,
    bool asTyping = false,
  }) {
    if (asTyping && _takesTypedNow(sessionId, requestId)) {
      _inFlight.add(sessionId);
      _sawWorking.remove(sessionId);
      log?.call('queue $sessionId: typed into the running turn');
      return const AdmitNow(midTurn: true);
    }
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
    // Sending again is going on: it joins the end and delivery resumes.
    _unpause(sessionId);
    if (!busy(sessionId) &&
        !dao.hasWaiting(sessionId) &&
        !_holdsNewMessages(sessionId)) {
      return null;
    }
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

  /// Puts a delegated child's result [text] into [sessionId]'s queue, waking
  /// it when idle. When [replacing] still waits, its text is replaced instead
  /// (a batch growing). Unlike a send, it never lifts
  /// a person's pause nor resumes a session nothing runs.
  QueuedMessage postDelegation(
    String sessionId,
    String text, {
    String? replacing,
    String? originId,
  }) {
    if (replacing != null && dao.editText(replacing, text, now: _now())) {
      _announce(sessionId);
      return dao.getById(replacing)!;
    }
    return _post(
      sessionId,
      text,
      origin: QueuedMessageOrigin.delegation,
      originId: originId,
    );
  }

  /// Queues [text] from the server itself, waking [sessionId] when idle but
  /// never lifting a pause nor resuming it.
  QueuedMessage _post(
    String sessionId,
    String text, {
    required QueuedMessageOrigin origin,
    String? originId,
  }) {
    final message = dao.enqueue(
      id: _newId(),
      sessionId: sessionId,
      text: text,
      origin: origin,
      originId: originId,
      now: _now(),
    );
    _withQueued.add(sessionId);
    log?.call('queue $sessionId: ${message.id} posted by the server');
    _announce(sessionId);
    _kick(sessionId);
    return message;
  }

  /// Reports the immediate delivery [admit] allowed. One typed [midTurn]
  /// starts no turn of its own: the running one's end is what to wait for.
  void afterImmediate(
    String sessionId, {
    required bool delivered,
    bool midTurn = false,
  }) {
    _inFlight.remove(sessionId);
    if (delivered && !midTurn) _awaitTurnStart(sessionId);
    _kick(sessionId);
  }

  /// Whether a person's send to [sessionId] goes into its running terminal
  /// turn now: its agent takes typed input there, none of a person's
  /// messages waits ahead of it (a server notice or a delegated result does
  /// not hold it back), nothing holds the queue, and nothing on screen would
  /// swallow the keys.
  static const _personOrigins = {
    QueuedMessageOrigin.app,
    QueuedMessageOrigin.device,
    QueuedMessageOrigin.companion,
  };

  bool _takesTypedNow(String sessionId, String? requestId) {
    if (!(takesInputMidTurn?.call(sessionId) ?? false)) return false;
    if (requestId != null &&
        requestId.isNotEmpty &&
        dao.byRequest(sessionId, requestId) != null) {
      return false;
    }
    if (_inFlight.contains(sessionId) || _held.contains(sessionId)) {
      return false;
    }
    if (status.acpRuntimeOf(sessionId) != null || !status.holds(sessionId)) {
      return false;
    }
    if (!turns.running(sessionId) && !_awaitingTurn.containsKey(sessionId)) {
      return false;
    }
    if (dao.hasWaitingFrom(sessionId, _personOrigins) ||
        _holdOf(sessionId) != null ||
        _holdsNewMessages(sessionId)) {
      return false;
    }
    final report = status.statusOf(sessionId)?.report;
    if (report != null && (report.hasOpenPrompt || report.hasOpenQuestion)) {
      return false;
    }
    return !_personTyping(sessionId);
  }

  /// The messages [sessionId] holds, queued, delivering or failed, in order.
  List<QueuedMessage> list(String sessionId) => _open(sessionId);

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

  /// Cancels queued message [id], or dismisses a failed one, at the word of
  /// [by] (`device:<id>`, `app`), which the row keeps.
  QueuedMessage cancel(String sessionId, String id, {String? by}) {
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
          cancelledBy: by,
        )) {
      throw DataRefused(
        DataRefusalCode.conflict,
        'this message is already ${_words(message.state)}, so it can no '
        'longer be cancelled',
      );
    }
    final cancelled = dao.getById(id)!;
    log?.call(
      'queue $sessionId: $id cancelled by ${by ?? 'an unnamed caller'}',
    );
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
    final kind = change.report.turnStatus;
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
    if (_personTyping(sessionId)) return false;
    final report = status.statusOf(sessionId)?.report;
    if (report != null && (report.hasOpenPrompt || report.hasOpenQuestion)) {
      return false;
    }
    // Only a real end of turn: idle or failed — background runs still going
    // are no turn — or a reader that cannot tell over a screen that has
    // stopped moving.
    return switch (report?.turnStatus) {
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
    if (_closed || deliver == null || _inFlight.contains(sessionId)) return;
    if (dao.head(sessionId) == null) {
      _withQueued.remove(sessionId);
      // Nothing left to hold: a later message is not born paused.
      _unpause(sessionId);
      return;
    }
    final hold = _holdOf(sessionId);
    if (_toldHold[sessionId] != hold) _announce(sessionId);
    // A new message resumes a session nothing runs; nothing else does.
    if (hold != null && !(resume && hold.kind == QueueHoldKind.stopped)) {
      return;
    }
    if (resume && _stopped(sessionId)) return _resumeFor(sessionId);
    if (!_ready(sessionId)) return;
    await _deliverHead(sessionId);
  }

  /// Delivers [sessionId]'s head now. Null when it went or none waits; else
  /// why not, in words — the head then queued again or failed.
  Future<String?> _deliverHead(String sessionId) async {
    final deliver = this.deliver;
    var head = dao.head(sessionId);
    if (deliver == null) return 'this server delivers no messages';
    if (head == null) {
      _withQueued.remove(sessionId);
      return null;
    }
    if (head.origin == QueuedMessageOrigin.delegation &&
        head.state == QueuedMessageState.queued) {
      switch (restate?.call(head)) {
        case '':
          if (!dao.transition(
            head.id,
            from: QueuedMessageState.queued,
            to: QueuedMessageState.cancelled,
            now: _now(),
            error: 'nothing in it still held when it was due',
          )) {
            return 'the next message is already on its way';
          }
          log?.call('queue $sessionId: ${head.id} out of date; cancelled');
          _announce(sessionId);
          return _deliverHead(sessionId);
        case final text? when text != head.text:
          if (dao.editText(head.id, text, now: _now())) {
            head = dao.getById(head.id)!;
          }
      }
    }
    if (!dao.transition(
      head.id,
      from: QueuedMessageState.queued,
      to: QueuedMessageState.delivering,
      now: _now(),
    )) {
      return 'the next message is already on its way';
    }
    _inFlight.add(sessionId);
    _sawWorking.remove(sessionId);
    _resumedForHead.remove(sessionId);
    _typingHolds.remove(sessionId)?.timer.cancel();
    _announce(sessionId);
    var delivered = false;
    String? why;
    try {
      await deliver(sessionId, head.text);
      delivered = true;
      _finish(head, QueuedMessageState.delivered);
      log?.call('queue $sessionId: ${head.id} delivered');
    } on DataRefused catch (refusal) {
      why = refusal.message;
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
      why = '$error';
      _finish(head, QueuedMessageState.failed, error: why);
    } finally {
      _inFlight.remove(sessionId);
      if (delivered) _awaitTurnStart(sessionId);
      if (dao.head(sessionId) == null) _withQueued.remove(sessionId);
      _announce(sessionId);
    }
    if (delivered) _kick(sessionId);
    return why;
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
      announce?.call(sessionId, _open(sessionId));

  /// [sessionId]'s open messages, each queued one marked with the hold.
  List<QueuedMessage> _open(String sessionId) {
    final open = dao.open(sessionId);
    final waiting = open.any((m) => m.state == QueuedMessageState.queued);
    final hold = _toldHold[sessionId] = waiting ? _holdOf(sessionId) : null;
    if (hold == null) return open;
    return [
      for (final message in open)
        message.state == QueuedMessageState.queued
            ? message.copyWith(hold: hold)
            : message,
    ];
  }

  // ---- Holds: what keeps a queue waiting past its turn's end.

  /// Looks again at every queue that waits: a resume armed, moved or ended
  /// changes what holds them.
  void refreshAll() {
    for (final sessionId in _withQueued.toList()) {
      _kick(sessionId);
    }
  }

  /// Holds [sessionId]'s waiting messages after the person stopped it,
  /// until they send again or ask for the next one ([sendNext]). An end
  /// cancels them instead ([ended]).
  void pause(String sessionId) {
    if (!dao.hasWaiting(sessionId) || !_paused.add(sessionId)) return;
    _savePaused();
    log?.call('queue $sessionId: paused, as the session was stopped');
    _announce(sessionId);
  }

  /// Cancels what still waits for [sessionId], which was ended on purpose,
  /// saying [reason] on each row, so nothing queued before the end resumes
  /// it. An agent that sent one is told, unless it is the one that ended it
  /// ([by]); a sender waiting on the row hears it settle.
  void ended(String sessionId, {required String reason, String? by}) {
    _unpause(sessionId);
    final cancelled = [
      for (final message in dao.open(sessionId))
        if (message.state == QueuedMessageState.queued &&
            dao.transition(
              message.id,
              from: QueuedMessageState.queued,
              to: QueuedMessageState.cancelled,
              now: _now(),
              error: reason,
              cancelledBy: kCancelledBySessionEnd,
            ))
          dao.getById(message.id)!,
    ];
    if (dao.head(sessionId) == null) _withQueued.remove(sessionId);
    if (cancelled.isEmpty) return;
    log?.call(
      'queue $sessionId: ended; ${cancelled.length} waiting message(s) '
      'cancelled',
    );
    for (final message in cancelled) {
      final sender = message.originId;
      final waited = _waiters.containsKey(message.id);
      _settle(message);
      if (message.origin != QueuedMessageOrigin.mcp ||
          sender == null ||
          sender == sessionId ||
          sender == by ||
          waited) {
        continue;
      }
      _post(
        sender,
        'Your message to session $sessionId was not delivered: $reason',
        origin: QueuedMessageOrigin.automation,
      );
    }
    _announce(sessionId);
  }

  /// Delivers [sessionId]'s head now, past any hold — resuming a session
  /// nothing runs to take it — and answers the row as it then stands. A
  /// pause stays for the messages behind it.
  Future<QueuedMessage> sendNext(String sessionId) async {
    final head =
        dao.head(sessionId) ??
        (throw const DataRefused.notFound('nothing waits in this queue'));
    if (busy(sessionId)) {
      throw const DataRefused(
        DataRefusalCode.conflict,
        "the session's turn is still running; the next message goes when "
        'it ends',
      );
    }
    if (_stopped(sessionId)) {
      await _resumeFor(sessionId);
    } else if (status.acpRuntimeOf(sessionId) == null &&
        !(resumesOnSend?.call(sessionId) ?? false) &&
        !status.holds(sessionId)) {
      throw const DataRefused.notFound(
        "this session isn't running, and this server cannot resume it",
      );
    } else {
      final why = await _deliverHead(sessionId);
      if (why != null && dao.getById(head.id)?.state == head.state) {
        throw DataRefused(DataRefusalCode.conflict, why);
      }
    }
    return dao.getById(head.id)!;
  }

  /// Delivers [sessionId]'s queued message [id] now, ahead of the rest: past
  /// a pause or a hold, resuming a session nothing runs, and into a terminal
  /// session's running turn as typing would. While the session cannot take
  /// it — an ACP turn runs, another message is on its way — it is refused
  /// and goes next. Answers the row as it then stands.
  Future<QueuedMessage> sendNow(String sessionId, String id) async {
    final message = _own(sessionId, id);
    if (message.state != QueuedMessageState.queued || !dao.moveToFront(id)) {
      throw DataRefused(
        DataRefusalCode.conflict,
        'this message is already ${_words(message.state)}, so it can no '
        'longer be sent now',
      );
    }
    _announce(sessionId);
    _refuseWhileTaken(sessionId, 'it goes next');
    if (_stopped(sessionId)) {
      await _resumeFor(sessionId);
    } else {
      _refuseNotRunning(sessionId);
      final midTurn = turns.running(sessionId);
      final why = await _deliverHead(sessionId);
      // Typed into the running turn, it starts none of its own: that turn's
      // end is the one to wait for.
      if (midTurn) _awaitingTurn.remove(sessionId)?.cancel();
      if (why != null && dao.getById(id)?.state == QueuedMessageState.queued) {
        throw DataRefused(DataRefusalCode.conflict, why);
      }
    }
    return dao.getById(id)!;
  }

  /// Delivers every message [sessionId] holds waiting now, together as one
  /// message, as [sendNow] delivers one. Answers them as they then stand.
  Future<List<QueuedMessage>> sendAll(String sessionId) async {
    final waiting = [
      for (final message in dao.open(sessionId))
        if (message.state == QueuedMessageState.queued) message,
    ];
    if (waiting.isEmpty) {
      throw const DataRefused.notFound('nothing waits in this queue');
    }
    _refuseWhileTaken(sessionId, 'they go one per turn as it ends');
    if (_stopped(sessionId)) {
      throw const DataRefused(
        DataRefusalCode.conflict,
        "this session isn't running: Resume now starts it with the next "
        'message',
      );
    }
    _refuseNotRunning(sessionId);
    final deliver =
        this.deliver ??
        (throw const DataRefused.unavailable(
          'this server delivers no messages',
        ));
    final claimed = [
      for (final message in waiting)
        if (dao.transition(
          message.id,
          from: QueuedMessageState.queued,
          to: QueuedMessageState.delivering,
          now: _now(),
        ))
          message,
    ];
    if (claimed.isEmpty) {
      throw const DataRefused(
        DataRefusalCode.conflict,
        'the messages are already on their way',
      );
    }
    _inFlight.add(sessionId);
    _sawWorking.remove(sessionId);
    _typingHolds.remove(sessionId)?.timer.cancel();
    _announce(sessionId);
    var delivered = false;
    try {
      await deliver(sessionId, [for (final m in claimed) m.text].join('\n\n'));
      delivered = true;
      for (final message in claimed) {
        _finish(message, QueuedMessageState.delivered);
      }
      log?.call('queue $sessionId: ${claimed.length} delivered together');
    } on DataRefused catch (refusal) {
      final nothingTyped =
          refusal.code == DataRefusalCode.notFound ||
          refusal.code == DataRefusalCode.conflict;
      for (final message in claimed) {
        if (nothingTyped) {
          dao.transition(
            message.id,
            from: QueuedMessageState.delivering,
            to: QueuedMessageState.queued,
            now: _now(),
          );
        } else {
          _finish(message, QueuedMessageState.failed, error: refusal.message);
        }
      }
      rethrow;
    } on Object catch (error) {
      for (final message in claimed) {
        _finish(message, QueuedMessageState.failed, error: '$error');
      }
      rethrow;
    } finally {
      _inFlight.remove(sessionId);
      if (delivered) _awaitTurnStart(sessionId);
      if (dao.head(sessionId) == null) _withQueued.remove(sessionId);
      _announce(sessionId);
    }
    return [for (final message in claimed) dao.getById(message.id)!];
  }

  /// Pauses [sessionId]'s queue at a person's word — nothing goes until
  /// they resume it, send again or send one now — or, with [paused] false,
  /// resumes it. Answers the open messages.
  List<QueuedMessage> setPaused(String sessionId, {required bool paused}) {
    if (paused) {
      if (!dao.hasWaiting(sessionId)) {
        throw const DataRefused.notFound('nothing waits in this queue');
      }
      if (_paused.add(sessionId)) {
        _savePaused();
        log?.call('queue $sessionId: paused by a person');
      }
    } else {
      _unpause(sessionId);
      _kick(sessionId);
    }
    _announce(sessionId);
    return list(sessionId);
  }

  /// Refuses while [sessionId] cannot take a message whatever its queue
  /// says: one is on its way, a switch holds it, or an ACP turn runs.
  void _refuseWhileTaken(String sessionId, String meanwhile) {
    final why = _inFlight.contains(sessionId)
        ? 'a message is already on its way'
        : _held.contains(sessionId)
        ? "the session's agent is being switched"
        : (status.acpRuntimeOf(sessionId)?.inTurn ?? false)
        ? 'the agent takes one message per turn and its turn is running'
        : null;
    if (why != null) {
      throw DataRefused(DataRefusalCode.conflict, '$why; $meanwhile');
    }
  }

  void _refuseNotRunning(String sessionId) {
    if (status.acpRuntimeOf(sessionId) == null &&
        !(resumesOnSend?.call(sessionId) ?? false) &&
        !status.holds(sessionId)) {
      throw const DataRefused.notFound(
        "this session isn't running, and this server cannot resume it",
      );
    }
  }

  /// [hostSessionId]'s agent started, by whatever path — Resume now, an
  /// opened session, an automatic continue, a limit's resume. Its start-up
  /// counts as a turn ([TurnSettlement.started]), whose end delivers what
  /// waits, holds still applying.
  void hostSessionStarted(String hostSessionId) {
    const prefix = 'karmashala_';
    if (!hostSessionId.startsWith(prefix)) return;
    final sessionId = hostSessionId.substring(prefix.length);
    if (hostSessionIdOf(sessionId) != hostSessionId) return;
    turns.started(sessionId);
    if (_withQueued.contains(sessionId)) _kick(sessionId);
  }

  /// Looks again at [hostSessionId]'s queue once its process ended: nothing
  /// runs it now, which its clients are told.
  void hostSessionEnded(String hostSessionId) {
    for (final sessionId in _withQueued) {
      if (hostSessionIdOf(sessionId) == hostSessionId) _kick(sessionId);
    }
  }

  /// Whether a person typed into [sessionId]'s terminal within
  /// [typingGrace]; the queue then looks again once they stop.
  bool _personTyping(String sessionId) {
    final typed = personTypedAt?.call(sessionId);
    final now = _now();
    final quietAt = typed?.add(typingGrace);
    final held = _typingHolds[sessionId];
    if (quietAt == null || !quietAt.isAfter(now)) {
      _typingHolds.remove(sessionId)?.timer.cancel();
      return false;
    }
    final since = held?.since ?? now;
    if (now.difference(since) >= typingHoldLimit) return false;
    held?.timer.cancel();
    _typingHolds[sessionId] = (
      since: since,
      timer: Timer(quietAt.difference(now), () => _kick(sessionId)),
    );
    return true;
  }

  void _unpause(String sessionId) {
    if (_paused.remove(sessionId)) _savePaused();
  }

  /// The pauses a restart found, kept only where messages still wait.
  void _loadPaused() {
    final raw = readPaused?.call();
    if (raw == null || raw.isEmpty) return;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      decoded = null;
    }
    final kept = [
      if (decoded is List)
        for (final id in decoded)
          if (id is String && dao.hasWaiting(id)) id,
    ];
    _paused.addAll(kept);
    if (decoded is! List || kept.length != decoded.length) _savePaused();
  }

  void _savePaused() => writePaused?.call(jsonEncode([..._paused]));

  QueueHold? _holdOf(String sessionId) {
    if (_paused.contains(sessionId)) {
      return const QueueHold(QueueHoldKind.paused);
    }
    final limit = limitHold?.call(sessionId);
    if (limit != null) return limit;
    if (_nothingRuns(sessionId)) return const QueueHold(QueueHoldKind.stopped);
    return null;
  }

  bool _nothingRuns(String sessionId) =>
      !_inFlight.contains(sessionId) &&
      !_resumedForHead.contains(sessionId) &&
      status.acpRuntimeOf(sessionId) == null &&
      !status.holds(sessionId);

  /// A resume armed for the reset takes even a new message's place.
  bool _holdsNewMessages(String sessionId) =>
      limitHold?.call(sessionId)?.until != null;

  // ---- A scheduled resume's message goes through here ([ResumeQueue]).

  @override
  Future<String> sendForResume(String sessionId, String message) async {
    if (dao.head(sessionId) case final head?) {
      final why = await _deliverHead(sessionId);
      if (why != null) throw StateError(why);
      log?.call('queue $sessionId: ${head.id} went in the resume\'s place');
      return head.text;
    }
    final deliver = this.deliver;
    if (busy(sessionId) || deliver == null) {
      // Delivered by the turn's end, past the hold the resume itself is.
      _enqueueAutomation(sessionId, message);
      return message;
    }
    _inFlight.add(sessionId);
    _sawWorking.remove(sessionId);
    var delivered = false;
    try {
      await deliver(sessionId, message);
      delivered = true;
      return message;
    } on DataRefused catch (refusal) {
      throw StateError(refusal.message);
    } finally {
      afterImmediate(sessionId, delivered: delivered);
    }
  }

  /// Queues a resume's [message] behind the running turn.
  void _enqueueAutomation(String sessionId, String message) {
    dao.enqueue(
      id: _newId(),
      sessionId: sessionId,
      text: message,
      origin: QueuedMessageOrigin.automation,
      now: _now(),
    );
    _withQueued.add(sessionId);
    _announce(sessionId);
  }

  @override
  QueuedMessage? claimHeadForResume(String sessionId) {
    if (_inFlight.contains(sessionId)) return null;
    final head = dao.head(sessionId);
    if (head == null ||
        !dao.transition(
          head.id,
          from: QueuedMessageState.queued,
          to: QueuedMessageState.delivering,
          now: _now(),
        )) {
      return null;
    }
    _inFlight.add(sessionId);
    _sawWorking.remove(sessionId);
    _announce(sessionId);
    return head;
  }

  @override
  void releaseClaimed(QueuedMessage claimed, {required bool sent}) {
    final sessionId = claimed.sessionId;
    _inFlight.remove(sessionId);
    if (sent) {
      _finish(claimed, QueuedMessageState.delivered);
      _awaitTurnStart(sessionId);
    } else {
      dao.transition(
        claimed.id,
        from: QueuedMessageState.delivering,
        to: QueuedMessageState.queued,
        now: _now(),
      );
    }
    _announce(sessionId);
    _kick(sessionId);
  }
}
