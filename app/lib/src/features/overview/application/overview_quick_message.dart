import 'package:agent_cli/descriptors.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/capabilities/capabilities.dart';
import '../../sessions/application/session_actions.dart';
import '../../sessions/application/session_status_providers.dart';

/// Where a quick message went.
enum QuickMessageOutcome {
  /// Typed into the agent now.
  sent,

  /// Held at the server until the turn running now ends.
  queued,
}

/// **A quick message from the Overview**, through the one send path every
/// composer uses ([SessionActions.continueSession]): a server holding a queue
/// keeps it until the agent's turn ends; anything else sends at once, and a
/// session that ended is resumed to take it.
class OverviewQuickMessage {
  OverviewQuickMessage(this._ref);

  final Ref _ref;

  /// Whether a message to [sessionId] now would wait for its turn to end.
  bool wouldQueue(String sessionId) {
    if (!_ref.read(capabilitiesProvider).sessionQueue) return false;
    final report = _ref.read(sessionStatusLookupProvider)(sessionId);
    return report?.turnStatus == AgentActivityStatus.working;
  }

  /// Sends [text] to [sessionId]; throws in words when it cannot.
  Future<QuickMessageOutcome> send(String sessionId, String text) async {
    final queued = wouldQueue(sessionId);
    await _ref.read(sessionActionsProvider).continueSession(sessionId, text);
    return queued ? QuickMessageOutcome.queued : QuickMessageOutcome.sent;
  }
}

final overviewQuickMessageProvider = Provider<OverviewQuickMessage>(
  OverviewQuickMessage.new,
);
