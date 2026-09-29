import 'dart:async';

import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../status/daemon_prompt_answers.dart';

/// **A client's chat sends and Stop, typed here as host keys** (Stage 2
/// step 2): past the write token, so a phone never takes a session's input or
/// resizes its terminal to its own grid. The typist is the one MCP
/// `session_send` uses, so the Return is read back off this server's screen.
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
  /// `requestId`: a resend joins or repeats the first answer and types
  /// nothing.
  Future<Object?> handle(SessionInputRequest<Object?> request, String? device) {
    final id = request.requestId;
    if (id == null || id.isEmpty || id.length > 128) return _run(request);
    _forgetOld();
    final key = '${device ?? 'local'}\u0000${request.kind}\u0000$id';
    final remembered = _ledger[key];
    if (remembered != null) {
      log?.call('${request.kind} $id repeated: answered as the first');
      return remembered.answer;
    }
    final answer = _run(request);
    _ledger[key] = _Remembered(answer, _now());
    // Nothing was typed into a session that is not here, so the id is free
    // for the send its client makes after resuming.
    unawaited(
      answer.then<void>(
        (_) {},
        onError: (Object error) {
          if (error is DataRefused && error.code == DataRefusalCode.notFound) {
            _ledger.remove(key);
          }
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

  bool _runsHere(String sessionId) =>
      prompts.status.runningSessionOf(sessionId) != null;

  static const _notHere = DataRefused.notFound(
    'this session is not running here',
  );

  Future<SessionSent> _send(String sessionId, String text) async {
    if (text.trim().isEmpty) {
      throw const DataRefused.invalid('there is no message to send');
    }
    if (!_runsHere(sessionId)) throw _notHere;
    final readable = prompts.agentOf(sessionId)?.menus?.markers != null;
    if (!readable) {
      log?.call(
        'sessions.send $sessionId: its composer cannot be read here, so the '
        'message is typed with one Return and not read back',
      );
    }
    final bool typed;
    try {
      typed = await typist.send(sessionId, text);
    } on SessionPromptRefusal catch (refusal) {
      throw DataRefused(
        DataRefusalCode.failed,
        'the agent did not take the Return: ${refusal.message}',
      );
    }
    if (!typed) throw _notHere;
    return SessionSent(
      sent: true,
      via: readable ? SessionSent.readBack : SessionSent.unverified,
    );
  }

  Future<DataAck> _interrupt(String sessionId) async {
    if (!_runsHere(sessionId) || !prompts.press(sessionId, _interruptKey)) {
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
