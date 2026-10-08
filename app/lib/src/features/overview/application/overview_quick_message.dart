import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show SessionSent;
import 'package:riverpod/riverpod.dart';

import '../../../core/capabilities/capabilities.dart';
import '../../sessions/application/session_actions.dart';
import '../../sessions/application/session_input.dart';
import '../../sessions/application/session_status_providers.dart';

/// What became of a quick message, as the server said: its [requestId], and
/// the server's answer to it — null when nothing answered for it (typed into
/// a pane this app runs, or a server older than the queue).
class QuickMessageSent {
  const QuickMessageSent({required this.requestId, this.reply});

  final String requestId;
  final SessionSent? reply;

  /// Held at the server until the turn running now ends.
  bool get queued => reply?.queued ?? false;

  /// Its place among the session's waiting messages, from 1.
  int? get position => reply?.position;

  /// The server's row for it, which its queue reports on.
  String? get rowId => reply?.queuedId ?? reply?.messageId;
}

/// **A quick message from the Overview**, through the one send path every
/// composer uses ([SessionActions.continueSession]), with a request id the
/// caller keeps for a retry of the same words: a server holding a queue
/// keeps it until the agent's turn ends; anything else sends at once, and a
/// session that ended is resumed to take it. Where it went is the server's
/// answer, never a guess made before sending.
class OverviewQuickMessage {
  OverviewQuickMessage(this._ref);

  final Ref _ref;

  /// Whether a message to [sessionId] now would likely wait for its turn to
  /// end — for a hint before typing, never for what is said after.
  bool wouldQueue(String sessionId) {
    if (!_ref.read(capabilitiesProvider).sessionQueue) return false;
    final report = _ref.read(sessionStatusLookupProvider)(sessionId);
    return report?.turnStatus == AgentActivityStatus.working;
  }

  /// Sends [text] to [sessionId] under [requestId] (a new one when null);
  /// throws in words when it cannot.
  Future<QuickMessageSent> send(
    String sessionId,
    String text, {
    String? requestId,
  }) async {
    final key = requestId ?? newSessionInputId();
    await _ref
        .read(sessionActionsProvider)
        .continueSession(sessionId, text, requestId: key);
    return QuickMessageSent(
      requestId: key,
      reply: _ref.read(sessionSendRepliesProvider)[key],
    );
  }
}

final overviewQuickMessageProvider = Provider<OverviewQuickMessage>(
  OverviewQuickMessage.new,
);
