import 'dart:math';

import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/capabilities/capabilities.dart';
import '../../../core/data/data_providers.dart';
import 'session_message_typist.dart';

/// **Where a person's message and Stop are typed.** A server that offers it
/// types them as host keys (`sessions.send`, `sessions.interrupt`), so this
/// client never takes the session's input or resizes its terminal; otherwise
/// they are typed into this client's own pane, as before.
class SessionInput {
  SessionInput(this._ref);

  final Ref _ref;

  static final _log = AppLogger.named('sessions.input');

  bool get viaServer => _ref.read(capabilitiesProvider).sendViaServer;

  /// Types [text] into [sessionId] and presses Return until it is taken.
  /// False when nothing runs the session: the caller resumes it. Throws
  /// [SessionPromptRefusal] in the server's words otherwise. [requestId] is
  /// the send's key, kept by the caller for a retry of the same message.
  Future<bool> send(String sessionId, String text, {String? requestId}) async {
    if (!viaServer) {
      return _ref.read(sessionMessageTypistProvider).send(sessionId, text);
    }
    try {
      final reply = await _ref
          .read(dataClientProvider)
          .send(
            SessionSend(
              sessionId: sessionId,
              text: text.trim(),
              requestId: requestId ?? newSessionInputId(),
            ),
          );
      _log.info('Sent to $sessionId through the server: ${reply.value.via}');
      return reply.value.sent;
    } on DataRefused catch (refusal) {
      if (refusal.code == DataRefusalCode.notFound) return false;
      throw SessionPromptRefusal(refusal.message);
    }
  }

  /// Presses the agent's interrupt key in [sessionId] through the server.
  /// False when the server does not run it. Throws [SessionPromptRefusal]
  /// in the server's words otherwise.
  Future<bool> interrupt(String sessionId) async {
    try {
      await _ref
          .read(dataClientProvider)
          .send(SessionInterrupt(sessionId, requestId: newSessionInputId()));
      return true;
    } on DataRefused catch (refusal) {
      if (refusal.code == DataRefusalCode.notFound) return false;
      throw SessionPromptRefusal(refusal.message);
    }
  }
}

final sessionInputProvider = Provider<SessionInput>(SessionInput.new);

final _random = Random.secure();

/// A fresh `requestId` for one act: one tap of Send or Stop.
String newSessionInputId() => [
  for (var i = 0; i < 16; i++)
    _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
].join();
