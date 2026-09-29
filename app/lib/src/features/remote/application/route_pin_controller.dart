import 'package:karmashala_remote/client.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_providers.dart';
import 'machines_providers.dart';

/// The active machine's route pin, and the one place that changes it: *Use
/// Auto* on the link strips today, a route picker when one is built. Auto on
/// this computer's own server.
class RoutePinController extends AsyncNotifier<CompanionRoutePin> {
  @override
  Future<CompanionRoutePin> build() async {
    final machines = ref.watch(machinesProvider);
    final active = ref.watch(activeMachineProvider);
    if (machines == null || active == null) return CompanionRoutePin.auto;
    // Read afresh: [activeMachineProvider] is the record as the session opened.
    final saved = (await CompanionConnections.load(
      machines.store,
    )).byHost(active.hostId.value);
    return (saved ?? active).pin;
  }

  /// Saves [pin] for the active machine and dials now. A resume in flight
  /// reloads the record, so it walks the new routes too.
  Future<void> choose(CompanionRoutePin pin) async {
    final machines = ref.read(machinesProvider);
    final active = ref.read(activeMachineProvider);
    if (machines == null || active == null) return;
    await machines.setPin(active.hostId.value, pin);
    state = AsyncData(pin);
    ref.invalidate(pairedMachinesProvider);
    ref.read(dataClientProvider).retry();
  }
}

final routePinProvider =
    AsyncNotifierProvider<RoutePinController, CompanionRoutePin>(
      RoutePinController.new,
    );
