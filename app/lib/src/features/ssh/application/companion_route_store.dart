import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show PreferenceStore;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/data_providers.dart';

/// How phones reach each SSH host: itself, or the hosted relay. Kept per host
/// because it is a fact about the box's network, and only once somebody chose —
/// an absent entry means "decide from the dial", never a default route.
class CompanionRouteStore {
  const CompanionRouteStore(this._preferences);

  final PreferenceStore _preferences;

  static String keyFor(String hostId) => 'ssh.companion_route.$hostId';

  HostRoute? read(String hostId) =>
      HostRoute.tryParse(_preferences.read(keyFor(hostId)));

  void write(String hostId, HostRoute route) =>
      _preferences.write(keyFor(hostId), route.wire);
}

final companionRouteStoreProvider = Provider<CompanionRouteStore>(
  (ref) => CompanionRouteStore(ref.watch(appPreferencesProvider)),
);

class _RouteRevision extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final _routeRevisionProvider = NotifierProvider<_RouteRevision, int>(
  _RouteRevision.new,
);

/// The route chosen for one host, re-read when [chooseCompanionRoute] writes.
final companionRouteProvider = Provider.family<HostRoute?, String>((ref, id) {
  ref.watch(_routeRevisionProvider);
  return ref.watch(companionRouteStoreProvider).read(id);
});

/// Records the choice and tells whoever is showing it.
void chooseCompanionRoute(WidgetRef ref, String hostId, HostRoute route) {
  ref.read(companionRouteStoreProvider).write(hostId, route);
  ref.read(_routeRevisionProvider.notifier).bump();
}

/// The route to open a pairing window on: what was chosen for this host, else
/// what the dial proved — reachable is itself, unreachable is the hosted relay.
HostRoute routeFor({required HostRoute? chosen, required bool reachable}) =>
    chosen ?? (reachable ? HostRoute.direct : HostRoute.relay);
