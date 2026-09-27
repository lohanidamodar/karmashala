import 'package:karmashala_session/delivery.dart';
import 'package:riverpod/riverpod.dart';

/// The last delivery reading each session's strip took, kept so the
/// Explorer's sections can read what rows already paid for without measuring
/// anything themselves. Presentation only: what a delivery asks of a person —
/// an inbox item — is the server's to decide (slice 5c), from its own poll.
class ObservedDeliveries extends Notifier<Map<String, SessionDelivery>> {
  @override
  Map<String, SessionDelivery> build() => const {};

  /// Records [delivery] as [sessionId]'s current reading.
  void observe(String sessionId, SessionDelivery delivery) {
    if (state[sessionId] == delivery) return;
    state = {...state, sessionId: delivery};
  }
}

final observedDeliveriesProvider =
    NotifierProvider<ObservedDeliveries, Map<String, SessionDelivery>>(
      ObservedDeliveries.new,
    );
