import 'dart:async';
import 'dart:convert';

import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../status/daemon_prompt_answers.dart';

/// **A client's chat sends and Stop, typed here as host keys** (Stage 2
/// step 2): past the write token, so a phone never takes a session's input or
/// resizes its terminal to its own grid. The typist is the one MCP
/// `session_send` uses, so the Return is read back off this server's screen.
/// Every session the server holds is served: its own PTYs and its copies of
/// sessions on SSH boxes.
class SessionInput {
  SessionInput({
    required this.prompts,
    required this.typist,
    this.log,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final DaemonPromptAnswers prompts;
  final SessionMessageTypist typist;
  final void Function(String message)? log;
  final DateTime Function() _now;

  /// How long a device's `requestId` is remembered: longer than any resend
  /// the link's resume grace can carry.
  static const Duration keep = Duration(minutes: 10);

  static const String _interruptKey = '\x1b';

  final Map<String, _Remembered> _ledger = {};

  /// Answers [request] from [device] (null: this machine), once per
  /// `requestId`: a resend of one that went through joins or repeats its
  /// answer and types nothing. A refused one is forgotten, so an explicit
  /// retry is tried again.
  Future<Object?> handle(SessionInputRequest<Object?> request, String? device) {
    final id = request.requestId;
    if (id == null || id.isEmpty || id.length > 128) return _run(request);
    _forgetOld();
    final sessionId = switch (request) {
      SessionSend(:final sessionId) => sessionId,
      SessionInterrupt(:final sessionId) => sessionId,
    };
    final key = [device ?? 'local', request.kind, sessionId, id].join('\u0000');
    final remembered = _ledger[key];
    if (remembered != null) {
      log?.call('${request.kind} $id repeated: answered as the first');
      return remembered.answer;
    }
    final answer = _run(request);
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

  Future<Object?> _run(SessionInputRequest<Object?> request) =>
      switch (request) {
        final SessionSend r => _send(r.sessionId, r.text),
        SessionInterrupt(:final sessionId) => _interrupt(sessionId),
      };

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

  Future<SessionSent> _send(String sessionId, String text) async {
    if (text.trim().isEmpty) {
      throw const DataRefused.invalid('there is no message to send');
    }
    final runtime = prompts.status.acpRuntimeOf(sessionId);
    if (runtime != null) {
      // The protocol takes one turn at a time; a message during one would
      // be refused by the agent, so it is refused here, in words.
      try {
        await runtime.send(text);
      } on StateError catch (error) {
        throw DataRefused(DataRefusalCode.conflict, error.message);
      }
      return const SessionSent(sent: true, via: viaProtocol);
    }
    if (!prompts.status.holds(sessionId)) throw _notHere;
    final report = prompts.status.statusOf(sessionId)?.report;
    if (report?.hasOpenQuestion ?? false) throw _questionOpen;
    if (report?.hasOpenPrompt ?? false) throw _promptOpen;
    final MessageDelivery delivery;
    try {
      delivery = await typist.deliver(sessionId, text);
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

  Future<DataAck> _interrupt(String sessionId) async {
    final runtime = prompts.status.acpRuntimeOf(sessionId);
    if (runtime != null) {
      runtime.cancel();
      return const DataAck();
    }
    if (!prompts.status.typeAsServer(sessionId, utf8.encode(_interruptKey))) {
      throw _notHere;
    }
    return const DataAck();
  }
}

final class _Remembered {
  _Remembered(this.answer, this.at);

  final Future<Object?> answer;
  final DateTime at;
}
