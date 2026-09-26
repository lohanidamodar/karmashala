/// The relay choices the pairing dialog offers, as tabs. One entry — the usual
/// case — renders no tab chrome at all; the shape is pinned by a test.
library;

import 'package:riverpod/riverpod.dart';

import '../application/remote_access_controller.dart';
import '../application/remote_access_settings.dart';
import '../application/ssh_relays.dart';
import '../relay_local/relay_endpoints.dart';

/// Where an endpoint's relay lives, which decides its icon and its story.
enum PairingRelayKind { local, sshHost, internet }

/// One relay the pairing dialog can root a code in.
class PairingRelayEndpoint {
  const PairingRelayEndpoint({
    required this.label,
    required this.url,
    required this.kind,
  });

  /// The tab's short name ("Internet", "Local network").
  final String label;

  final Uri url;
  final PairingRelayKind kind;

  @override
  bool operator ==(Object other) =>
      other is PairingRelayEndpoint &&
      other.label == label &&
      other.url == url &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(label, url, kind);

  @override
  String toString() =>
      'PairingRelayEndpoint($label, ${redactRelayUrl(url)}, ${kind.name})';
}

/// The endpoints the dialog shows, one per relay the host is serving. **Empty
/// is real**: with every relay off, no code could be redeemed.
final pairingRelayEndpointsProvider = Provider<List<PairingRelayEndpoint>>((
  ref,
) {
  final offered = ref.watch(relayEndpointsProvider);
  if (offered.isNotEmpty) {
    return [
      for (final option in offered)
        PairingRelayEndpoint(
          label: option.label,
          url: option.url,
          kind: switch (option.kind) {
            RelayEndpointKind.local => PairingRelayKind.local,
            RelayEndpointKind.sshHost => PairingRelayKind.sshHost,
            RelayEndpointKind.internet => PairingRelayKind.internet,
          },
        ),
    ];
  }
  final access = ref.watch(remoteAccessSettingsProvider);
  if (access.enabled) return const [];
  return [
    PairingRelayEndpoint(
      label: 'Internet',
      url: hostedRelayOf(access),
      kind: PairingRelayKind.internet,
    ),
  ];
});
