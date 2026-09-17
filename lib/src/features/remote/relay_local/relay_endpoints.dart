/// Which relay endpoints can carry a pairing RIGHT NOW: every active one, since
/// the host listens on both. Each tab pairs a phone onto that relay for good.
library;

import 'package:riverpod/riverpod.dart';

import '../../settings/application/settings_controller.dart';
import '../application/relay_prefs.dart';
import '../application/ssh_relays.dart';
import '../application/remote_access_controller.dart';
import 'local_relay_providers.dart';
import 'local_relay_service.dart';

enum RelayEndpointKind { local, sshHost, internet }

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
  String toString() =>
      'RelayEndpointOption($label, ${redactRelayUrl(url)}, ${kind.name})';
}

/// Empty while remote access is off or no relay is usable — a tab no phone
/// can dial would only pretend. Local first: it always works on a shared net.
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
  // The user's own boxes before somebody else's relay: if one is set up, it
  // is what they would rather new phones pair through.
  for (final entry in ref.watch(sshRelaysProvider)) {
    if (!entry.enabled) continue;
    options.add(
      RelayEndpointOption(
        label: entry.hostName,
        url: entry.url,
        kind: RelayEndpointKind.sshHost,
      ),
    );
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
