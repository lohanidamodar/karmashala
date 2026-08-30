import '../../sessions/domain/session_delivery.dart';
import 'watched_session.dart';

/// One session's delivery state, and what it was the last time it was read.
///
/// The shape [AgentNotificationPolicy.newsInDelivery] needs, and the reason the
/// classifier can stay a pure function: whether a red build is *news* depends
/// entirely on whether it was already red, and nothing but the caller knows
/// that.
class DeliveryTransition {
  const DeliveryTransition({
    required this.session,
    required this.to,
    this.from,
  });

  final WatchedSession session;

  /// The previous reading, or null when this is the first one — which counts as
  /// "nothing was true", so a change that happened while the app was closed is
  /// still news the first time it is seen.
  final SessionDelivery? from;

  final SessionDelivery to;

  @override
  String toString() =>
      'DeliveryTransition(${session.label}: ${from?.stage.name} -> '
      '${to.stage.name})';
}
