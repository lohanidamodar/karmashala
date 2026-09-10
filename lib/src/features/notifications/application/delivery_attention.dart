import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import '../../sessions/application/session_providers.dart';
import 'package:karmashala_session/delivery.dart';
import '../domain/agent_session_key.dart';
import '../domain/delivery_transition.dart';
import '../domain/inbox_item.dart';
import '../domain/notification_policy.dart';
import '../domain/watched_session.dart';
import 'attention_inbox.dart';

/// Turns delivery state into attention-inbox items. No poller of its own: it
/// only judges readings the delivery providers already fetched to draw a row.
class DeliveryAttentionController
    extends Notifier<Map<String, SessionDelivery>> {
  @override
  Map<String, SessionDelivery> build() => const {};

  /// Records [delivery] as the current state of [sessionId], filing an inbox
  /// item when that is news.
  void observe(String sessionId, SessionDelivery delivery) {
    final previous = state[sessionId];
    if (previous == delivery) return;
    state = {...state, sessionId: delivery};

    final session = _watchedSession(sessionId);
    if (session == null) return;
    final reason = const AgentNotificationPolicy()
        .newsInDelivery(
          DeliveryTransition(session: session, from: previous, to: delivery),
        )
        .reason;
    if (reason == null) return;

    // Into the inbox only: delivery news arrives on a two-minute tick, so a
    // toast would land minutes after the fact with no way to say how stale.
    ref
        .read(attentionInboxProvider.notifier)
        .apply(InboxUpdate(news: [(session: session, reason: reason)]));
  }

  /// The session in the terms the inbox talks about. Built here, not through
  /// `WatchedSessionLoader`, which would drop a session with no CLI id.
  WatchedSession? _watchedSession(String sessionId) {
    final session = ref.read(sessionDaoProvider).getById(sessionId);
    if (session == null) return null;
    final agentId = ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId)
        ?.agentId;
    return WatchedSession(
      key: AgentSessionKey(
        agentId ?? 'unknown',
        session.externalSessionId ?? session.id,
      ),
      label: session.title,
      openId: session.id,
      imported: false,
    );
  }
}

final deliveryAttentionProvider =
    NotifierProvider<DeliveryAttentionController, Map<String, SessionDelivery>>(
      DeliveryAttentionController.new,
    );
