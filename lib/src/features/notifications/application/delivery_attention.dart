import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/application/agent_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/domain/session_delivery.dart';
import '../domain/agent_session_key.dart';
import '../domain/delivery_transition.dart';
import '../domain/inbox_item.dart';
import '../domain/notification_policy.dart';
import '../domain/watched_session.dart';
import 'attention_inbox.dart';

/// Turns delivery state into attention-inbox items.
///
/// **It has no poller of its own.** Every reading it judges is one the delivery
/// providers had already fetched to draw a row with, so a pull request that
/// nobody is looking at costs nothing and produces no items. The honest limit
/// of that trade: a session whose row is not rendered anywhere raises no
/// delivery news until something asks about it. In practice the Explorer draws
/// every session, so "rendered somewhere" is the normal case — and the moment
/// it is not, the alternative would have been a second `gh` poller running for
/// rows nobody can see.
///
/// The last reading per session is kept because that is the only thing the
/// classifier cannot work out for itself: whether a red build is *news* depends
/// entirely on whether it was already red.
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

    // Into the inbox only. A toast is an interruption and delivery news arrives
    // on a two-minute tick, so it would land minutes after the fact with no way
    // to tell how stale it was; the inbox is a work list and carries it
    // honestly.
    ref
        .read(attentionInboxProvider.notifier)
        .apply(InboxUpdate(news: [(session: session, reason: reason)]));
  }

  /// The session in the terms the inbox talks about.
  ///
  /// Built here rather than looked up through `WatchedSessionLoader`, which
  /// enumerates and filters *every* session for the status poller and would
  /// drop the ones this cares about: a session with no CLI session id still has
  /// a branch, a pull request and a place in the inbox.
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
