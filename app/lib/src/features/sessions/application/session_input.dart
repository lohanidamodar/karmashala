import 'dart:math';

import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/capabilities/capabilities.dart';
import '../../../core/data/data_providers.dart';
import 'session_message_typist.dart';

/// **What the server answered each send**, by the request id it carried
/// ([SessionSent]: delivered at once, or queued at a place with its row's
/// id). Read by a sender that shows what became of its message — the
/// dashboard's quick box, batch replies and Ctrl+K's `message` — from the
/// server's own words rather than a guess. The most recent few only.
class SessionSendReplies extends Notifier<Map<String, SessionSent>> {
  static const _kept = 64;

  @override
  Map<String, SessionSent> build() => const {};

  void record(String requestId, SessionSent sent) {
    final next = {...state}..remove(requestId);
    next[requestId] = sent;
    while (next.length > _kept) {
      next.remove(next.keys.first);
    }
    state = next;
  }
}

final sessionSendRepliesProvider =
    NotifierProvider<SessionSendReplies, Map<String, SessionSent>>(
      SessionSendReplies.new,
    );

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
  /// False when neither the server nor a pane here runs the session. Throws
  /// [SessionPromptRefusal] in the server's words otherwise. [requestId] is
  /// the send's key, kept by the caller for a retry of the same message.
  Future<bool> send(String sessionId, String text, {String? requestId}) async {
    final local = _ref.read(sessionMessageTypistProvider);
    if (!viaServer) return local.send(sessionId, text);
    final key = requestId ?? newSessionInputId();
    try {
      final reply = await _ref
          .read(dataClientProvider)
          .send(
            SessionSend(
              sessionId: sessionId,
              text: text.trim(),
              requestId: key,
            ),
          );
      final sent = reply.value;
      // Kept by its key, for a sender that shows what became of it.
      _ref.read(sessionSendRepliesProvider.notifier).record(key, sent);
      _log.info(
        sent.queued
            ? 'Queued for $sessionId at the server, place ${sent.position}'
            : 'Sent to $sessionId through the server: ${sent.via}',
      );
      return sent.sent;
    } on DataRefused catch (refusal) {
      if (refusal.code != DataRefusalCode.notFound) {
        throw SessionPromptRefusal(refusal.message);
      }
      if (!_ref.read(capabilitiesProvider).typesIntoOwnPanes) {
        throw const SessionPromptRefusal(
          'the server is not holding this session right now — it may be '
          'restarting — so nothing was sent. Send it again in a moment',
        );
      }
    }
    // A session the server cannot type into — a box whose link is down, a
    // pane this app runs itself — is typed into a pane here, as before step 2.
    _log.info('The server does not run $sessionId: typing into a pane here');
    return local.send(sessionId, text);
  }

  /// Presses the agent's interrupt key in [sessionId] through the server.
  /// False when the server does not run it: the caller presses it in a pane
  /// here. Throws [SessionPromptRefusal] in the server's words otherwise.
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
