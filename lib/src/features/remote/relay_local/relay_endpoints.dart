/// The seam the pairing dialog's tabs read: which relay endpoints can carry a
/// pairing RIGHT NOW. The host dials exactly one relay, so the list holds the
/// active choice — the embedded local relay when "This computer" is selected
/// and it is actually running with a LAN address, the hosted relay otherwise.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/application/settings_controller.dart';
import '../../settings/domain/relay_mode.dart';
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

/// Empty while remote access is off, or while the local relay is chosen but
/// not reachable (starting, bind failed, no LAN address) — a tab offering an
/// endpoint no phone can dial would only pretend.
final relayEndpointsProvider = Provider<List<RelayEndpointOption>>((ref) {
  final settings = ref.watch(settingsControllerProvider);
  if (!settings.remoteAccessEnabled) return const [];
  if (settings.remoteRelayMode == RelayMode.local) {
    final status = ref.watch(localRelayStatusProvider);
    final primary = status.primaryUrl;
    if (status.state != LocalRelayState.running || primary == null) {
      return const [];
    }
    return [
      RelayEndpointOption(
        label: 'Local network',
        url: primary,
        kind: RelayEndpointKind.local,
      ),
    ];
  }
  return [
    RelayEndpointOption(
      label: 'Internet',
      url: resolveRelayUri(settings.remoteRelayUrl),
      kind: RelayEndpointKind.internet,
    ),
  ];
});
