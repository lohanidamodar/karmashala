/// The seam the pairing dialog's tabs read: which relay endpoints can carry a
/// pairing RIGHT NOW.
///
/// Since Loop 80 the host listens on both relays at once, so this offers
/// **every active one**: the embedded local relay while it is running with a
/// LAN address, the hosted relay while its switch is on. Both on means two
/// tabs, each pairing a phone onto that relay for good.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/application/settings_controller.dart';
import '../application/relay_prefs.dart';
import '../application/remote_access_controller.dart';
import 'local_relay_providers.dart';
import 'local_relay_service.dart';

enum RelayEndpointKind { local, internet }

/// One offerable relay endpoint: what a pairing tab shows and what the QR's
/// `relay` field carries.
class RelayEndpointOption {
  const RelayEndpointOption({
    required this.label,
    required this.url,
    required this.kind,
  });

  final String label;
  final Uri url;
  final RelayEndpointKind kind;

  @override
  bool operator ==(Object other) =>
      other is RelayEndpointOption &&
      other.label == label &&
      other.url == url &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(label, url, kind);

  @override
  String toString() => 'RelayEndpointOption($label, $url, ${kind.name})';
}

/// Empty while remote access is off, or while neither relay is usable — a tab
/// offering an endpoint no phone can dial would only pretend. Local first: on
/// the network you share with the phone it is the one that always works.
final relayEndpointsProvider = Provider<List<RelayEndpointOption>>((ref) {
  final settings = ref.watch(settingsControllerProvider);
  if (!settings.remoteAccessEnabled) return const [];
  final prefs = ref.watch(relayPrefsProvider);
  final options = <RelayEndpointOption>[];

  if (prefs.localEnabled) {
    final status = ref.watch(localRelayStatusProvider);
    final primary = status.primaryUrl;
    if (status.state == LocalRelayState.running && primary != null) {
      options.add(
        RelayEndpointOption(
          label: 'Local network',
          url: primary,
          kind: RelayEndpointKind.local,
        ),
      );
    }
  }
  if (prefs.hostedEnabled) {
    options.add(
      RelayEndpointOption(
        label: 'Internet',
        url: resolveRelayUri(settings.remoteRelayUrl),
        kind: RelayEndpointKind.internet,
      ),
    );
  }
  return options;
});
