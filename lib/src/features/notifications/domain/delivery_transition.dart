import '../../sessions/domain/session_delivery.dart';
import 'watched_session.dart';

/// One session's delivery state, and what it was the last time it was read —
/// whether a red build is *news* depends on whether it was already red.
class DeliveryTransition {
  const DeliveryTransition({
    required this.session,
    required this.to,
    this.from,
  });

  final WatchedSession session;

  /// The previous reading, or null on the first — which counts as "nothing was
  /// true", so a change made while the app was closed is still news once.
  final SessionDelivery? from;

  final SessionDelivery to;

  @override
  String toString() =>
      'DeliveryTransition(${session.label}: ${from?.stage.name} -> '
      '${to.stage.name})';
}
