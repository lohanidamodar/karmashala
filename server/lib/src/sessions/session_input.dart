import 'dart:async';
import 'dart:convert';

import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/session.dart'
    show QueuedMessage, QueuedMessageOrigin;

import '../acp/acp_session_runtime.dart';
import '../status/daemon_prompt_answers.dart';
import 'session_queue.dart';

/// **A client's chat sends and Stop, typed here as host keys** (Stage 2
/// step 2): past the write token, so a phone never takes a session's input or
/// resizes its terminal to its own grid. The typist is the one MCP
/// `session_send` uses, so the Return is read back off this server's screen.
/// Every session the server holds is served: its own PTYs and its copies of
/// sessions on SSH boxes.
///
/// A session whose agent the server speaks to over a protocol
/// ([resumesOnSend]) and that nothing runs any more is resumed here to take
/// the message ([resume]: `session/load` where the agent can, a fresh
/// conversation in the same row otherwise), so every client — a phone,
/// another desktop, an agent's `session_send` — continues it alike. A resume
/// refused is answered in its words, and nothing is sent.
///
/// With a [queue], a send while the turn runs waits there and is delivered
/// by [deliverNow] when the turn ends.
class SessionInput {
  SessionInput({
    required this.prompts,
    required this.typist,
    this.resumesOnSend,
    this.resume,
    this.queue,
    this.log,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    queue?.deliver = (sessionId, text) => deliverNow(sessionId, text);
  }

  final DaemonPromptAnswers prompts;
  final SessionMessageTypist typist;

  /// Whether row [String] is resumed by a send when nothing runs it.
  final bool Function(String sessionId)? resumesOnSend;

  /// Resumes row [String] at the server, starting it with [prompt] as its
  /// first turn — `ServerSessionLauncher.resume`.
  final Future<SessionStarted> Function(String sessionId, String prompt)?
  resume;

  /// Where a send waits while the session's turn runs; null sends at once.
  final SessionQueue? queue;
  final void Function(String message)? log;
  final DateTime Function() _now;

  /// Told each session a client stopped — a delegated child's result then
  /// stays the person's (`DelegationResults.stopped`).
  void Function(String sessionId)? interrupted;

  /// How long a device's `requestId` is remembered: longer than any resend
  /// the link's resume grace can carry.
  static const Duration keep = Duration(minutes: 10);

  static const String _interruptKey = '\x1b';

  final Map<String, _Remembered> _ledger = {};

  /// Answers [request] from [device] (null: this machine), once per
  /// `requestId`: a resend of one that went through joins or repeats its
  /// answer and types nothing. A refused one is forgotten, so an explicit
  /// retry is tried again. [origin] names a sender other than a data link.
  Future<Object?> handle(
    SessionInputRequest<Object?> request,
    String? device, {
    QueuedMessageOrigin? origin,
  }) {
    final id = request.requestId;
    if (id == null || id.isEmpty || id.length > 128) {
      return _run(request, device, origin);
    }
    _forgetOld();
    final key = [
      device ?? 'local',
      request.kind,
      request.sessionId,
      id,
    ].join('\u0000');
    final remembered = _ledger[key];
    if (remembered != null) {
      log?.call('${request.kind} $id repeated: answered as the first');
      return remembered.answer;
    }
    final answer = _run(request, device, origin);
    final entry = _ledger[key] = _Remembered(answer, _now());
    unawaited(
      answer.then<void>(
        (_) {},
        onError: (Object _) {
          if (identical(_ledger[key], entry)) _ledger.remove(key);
        },
      ),
    );
    return answer;
  }

  /// Every refusal is logged as well as answered: the sender's only other
  /// trace of it is a snackbar.
  Future<Object?> _run(
    SessionInputRequest<Object?> request,
    String? device,
    QueuedMessageOrigin? origin,
  ) async {
    try {
      return await switch (request) {
        final SessionSend r => _send(
          r.sessionId,
          r.text,
          origin:
              origin ??
              (device == null
                  ? QueuedMessageOrigin.app
                  : QueuedMessageOrigin.device),
          originId: device,
          requestId: r.requestId,
        ),
        SessionInterrupt(:final sessionId) => _interrupt(sessionId),
        SessionQueueList(:final sessionId) => Future.value(
          _queue().list(sessionId),
        ),
        SessionQueueEdit(:final sessionId, :final id, :final text) =>
          Future<QueuedMessage>.sync(() => _queue().edit(sessionId, id, text)),
        SessionQueueSendNext(:final sessionId) => _queue().sendNext(sessionId),
        SessionQueueCancel(:final sessionId, :final id) =>
          Future<QueuedMessage>.sync(() => _queue().cancel(sessionId, id)),
      };
    } on DataRefused catch (refusal) {
      log?.call(
        '${request.kind} ${request.sessionId} refused: ${refusal.message}',
      );
      rethrow;
    }
  }

  SessionQueue _queue() =>
      queue ??
      (throw const DataRefused.unavailable('this server queues no messages'));

  void _forgetOld() {
    final cutoff = _now().subtract(keep);
    _ledger.removeWhere((_, remembered) => remembered.at.isBefore(cutoff));
  }

  static const _notHere = DataRefused.notFound(
    'this session is not running here',
  );

  /// As MCP `session_send` refuses: text typed into an open prompt presses
  /// its keys — its Return picks the default — and is never sent.
  static const _promptOpen = DataRefused(
    DataRefusalCode.conflict,
    'the session has an approval prompt open, so nothing was sent — the '
    'message would have been typed into the prompt. Answer it, then send',
  );

  static const _questionOpen = DataRefused(
    DataRefusalCode.conflict,
    'the session is asking a multiple-choice question, so nothing was sent — '
    'the message would have been typed into the question. Answer it, then '
    'send',
  );

  /// How a message reached an agent spoken to over ACP: as `session/prompt`,
  /// with no screen to read a Return back off.
  static const String viaProtocol = 'protocol';

  Future<SessionSent> _send(
    String sessionId,
    String text, {
    required QueuedMessageOrigin origin,
    String? originId,
    String? requestId,
  }) async {
    if (text.trim().isEmpty) {
      throw const DataRefused.invalid('there is no message to send');
    }
    final queue = this.queue;
    if (queue == null) return deliverNow(sessionId, text);
    switch (queue.admit(
      sessionId,
      text,
      origin: origin,
      originId: originId,
      requestId: requestId,
    )) {
      case AdmitQueued(:final message, :final position):
        return SessionSent(
          sent: true,
          via: SessionSent.queuedVia,
          queuedId: message.id,
          position: position,
        );
      case AdmitNow():
        var delivered = false;
        try {
          final sent = await deliverNow(sessionId, text);
          delivered = true;
          return sent;
        } finally {
          queue.afterImmediate(sessionId, delivered: delivered);
        }
    }
  }

  /// Delivers [text] to [sessionId] now: over its protocol, by resuming it,
  /// or typed into its screen, after [leadIn] typed on its own. Refused in
  /// words when it cannot be.
  Future<SessionSent> deliverNow(
    String sessionId,
    String text, {
    String? leadIn,
  }) async {
    if (text.trim().isEmpty) {
      throw const DataRefused.invalid('there is no message to send');
    }
    final runtime = prompts.status.acpRuntimeOf(sessionId);
    if (runtime != null) return _sendOverProtocol(runtime, text);
    final resume = this.resume;
    if (resume != null && (resumesOnSend?.call(sessionId) ?? false)) {
      return _resumeToSend(sessionId, text, resume);
    }
    if (!prompts.status.holds(sessionId)) throw _notHere;
    final report = prompts.status.statusOf(sessionId)?.report;
    if (report?.hasOpenQuestion ?? false) throw _questionOpen;
    if (report?.hasOpenPrompt ?? false) throw _promptOpen;
    final MessageDelivery delivery;
    try {
      delivery = await typist.deliver(sessionId, text, leadIn: leadIn);
    } on SessionPromptRefusal catch (refusal) {
      throw DataRefused(
        DataRefusalCode.failed,
        'the agent did not take the Return: ${refusal.message}',
      );
    }
    switch (delivery) {
      case MessageDelivery.none:
        throw _notHere;
      case MessageDelivery.unverified:
        log?.call(
          'sessions.send $sessionId: the message was typed with one Return '
          'that could not be read back off the screen',
        );
        return const SessionSent(sent: true, via: SessionSent.unverified);
      case MessageDelivery.readBack:
        return const SessionSent(sent: true, via: SessionSent.readBack);
    }
  }

  /// The protocol takes one turn at a time; a message during one would be
  /// refused by the agent, so it is refused here, in words.
  static Future<SessionSent> _sendOverProtocol(
    AcpSessionRuntime runtime,
    String text, {
    bool resumed = false,
    String? notice,
  }) async {
    final String? said;
    try {
      said = await runtime.send(text);
    } on StateError catch (error) {
      throw DataRefused(DataRefusalCode.conflict, error.message);
    }
    final words = [?notice, ?said].join(' ');
    return SessionSent(
      sent: true,
      via: viaProtocol,
      resumed: resumed,
      notice: words.isEmpty ? null : words,
    );
  }

  /// Resumes [sessionId] with [text] as its first turn. One that came to run
  /// meanwhile is answered as it is, and sent to.
  Future<SessionSent> _resumeToSend(
    String sessionId,
    String text,
    Future<SessionStarted> Function(String, String) resume,
  ) async {
    // Said before it starts: an agent's start can take minutes.
    log?.call(
      'sessions.send $sessionId: nothing runs it; resuming it at the server '
      'to take the message',
    );
    final SessionStarted started;
    try {
      started = await resume(sessionId, text);
    } on DataRefused {
      rethrow;
    } on Object catch (error) {
      final words = switch (error) {
        StateError(:final message) => message,
        ArgumentError(:final message) => '$message',
        _ => '$error',
      };
      throw DataRefused(
        DataRefusalCode.failed,
        'This session is not running and could not be resumed to take the '
        'message, so nothing was sent: $words',
      );
    }
    final notice = started.workingDirectoryNotice;
    log?.call(
      'sessions.send $sessionId: resumed at the server to take the message'
      '${notice == null ? '' : ' ($notice)'}',
    );
    if (started.adopted) {
      final runtime = prompts.status.acpRuntimeOf(sessionId);
      if (runtime == null) throw _notHere;
      return _sendOverProtocol(runtime, text, resumed: false, notice: notice);
    }
    return SessionSent(
      sent: true,
      via: viaProtocol,
      resumed: true,
      notice: notice,
    );
  }

  /// Stop also pauses the queue: the turn's end it causes must not send the
  /// next message the person just stopped short of.
  Future<DataAck> _interrupt(String sessionId) async {
    interrupted?.call(sessionId);
    final runtime = prompts.status.acpRuntimeOf(sessionId);
    if (runtime != null) {
      queue?.pause(sessionId);
      runtime.cancel();
      return const DataAck();
    }
    if (!prompts.status.typeAsServer(sessionId, utf8.encode(_interruptKey))) {
      throw _notHere;
    }
    queue?.pause(sessionId);
    return const DataAck();
  }
}

final class _Remembered {
  _Remembered(this.answer, this.at);

  final Future<Object?> answer;
  final DateTime at;
}
