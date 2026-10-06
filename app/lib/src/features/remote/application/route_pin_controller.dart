import 'package:karmashala_remote/client.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/server/remote_server_access.dart';
import '../../terminal/application/local_host_providers.dart';
import 'machines_providers.dart';

/// The active machine's route pin, and the one place that changes any
/// machine's: *Use Auto* on the link strips, and the route picker on a
/// machine's row in Settings → Machines. Auto on this computer's own server.
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

  /// Saves [pin] for [hostId]'s machine, the active one when null. For the
  /// active machine it also dials now: a live link on a route [pin] does not
  /// allow is hung up and redialled under it, and a resume in flight reloads
  /// the record, so it walks the new routes too. Another machine obeys it at
  /// its next dial.
  Future<void> choose(CompanionRoutePin pin, {String? hostId}) async {
    final machines = ref.read(machinesProvider);
    if (machines == null) return;
    final active = ref.read(activeMachineProvider);
    final target = hostId ?? active?.hostId.value;
    if (target == null) return;
    await machines.setPin(target, pin);
    ref.invalidate(pairedMachinesProvider);
    if (target != active?.hostId.value) return;
    state = AsyncData(pin);
    final access = ref.read(serverAccessProvider);
    if (access is RemoteServerAccess) await access.obey(pin);
    ref.read(dataClientProvider).retry();
  }
}

final routePinProvider =
    AsyncNotifierProvider<RoutePinController, CompanionRoutePin>(
      RoutePinController.new,
    );
