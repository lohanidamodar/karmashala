import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/capabilities/capabilities.dart';
import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';

/// The concurrency limits, how full each is, and who waits for a slot, as
/// the server last told. Empty against a server without limits.
final capacityProvider = StreamProvider<CapacitySnapshot>((ref) {
  if (!ref.watch(capabilitiesProvider.select((c) => c.sessionCapacity))) {
    return Stream.value(CapacitySnapshot.empty);
  }
  final client = ref.watch(dataClientProvider);
  return (() async* {
    yield client.capacity;
    yield* client.capacityChanges;
  })();
});

/// The snapshot now, empty until the first is told.
final capacityNowProvider = Provider<CapacitySnapshot>(
  (ref) => ref.watch(capacityProvider).value ?? CapacitySnapshot.empty,
);

/// [sessionId]'s wait for a slot, or null when it is not waiting.
final sessionSlotWaitProvider = Provider.family<LaunchWaiter?, String>(
  (ref, sessionId) =>
      ref.watch(capacityNowProvider.select((c) => c.waiterFor(sessionId))),
);

/// What a person does about a wait.
class CapacityActions {
  const CapacityActions(this._client);
  final DataClient _client;

  /// Starts it now, over the limits; ask first.
  Future<void> startAnyway(String ticketId) async {
    await _client.send(SessionWaitStartAnyway(ticketId));
  }

  Future<void> cancel(String ticketId) async {
    await _client.send(SessionWaitCancel(ticketId));
  }
}

final capacityActionsProvider = Provider<CapacityActions>(
  (ref) => CapacityActions(ref.watch(dataClientProvider)),
);

/// "3/4 running · 2 waiting", for the dashboard's summary — null while no
/// limit is set, nothing waits and background work is not paused.
String? capacitySummary(CapacitySnapshot capacity) {
  final limits = capacity.limits;
  final waiting = capacity.waiters.length;
  if (!limits.hasLimits && waiting == 0 && !limits.pauseBackground) {
    return null;
  }
  final global = limits.global;
  return [
    global == null
        ? '${capacity.running} running'
        : '${capacity.running}/$global running',
    if (waiting > 0) '$waiting waiting',
    if (limits.pauseBackground) 'background paused',
  ].join(' · ');
}
