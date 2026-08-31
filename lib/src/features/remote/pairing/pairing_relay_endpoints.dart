/// The relay choices the pairing dialog offers, as tabs.
///
/// The default is exactly one entry — the configured internet relay — and the
/// dialog then renders no tab chrome at all. Loop 77's embedded local relay
/// overrides this provider to add a "Local network" entry
/// (`ws://<lan-ip>:<port>`) so pairing works with one click when the internet
/// relay is unreachable.
/// The contract is pinned by `pairing_relay_endpoints_test.dart`: keep the
/// shape stable so the local-relay loop can feed it without touching the
/// dialog.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/application/settings_controller.dart';
import '../application/remote_access_controller.dart';
import '../relay_local/relay_endpoints.dart';

/// Where an endpoint's relay lives, which decides its icon and its story.
enum PairingRelayKind { local, internet }

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
  String toString() => 'PairingRelayEndpoint($label, $url, ${kind.name})';
}

/// The endpoints the dialog shows, in tab order. Never empty: what the
/// embedded local relay currently offers ([relayEndpointsProvider]), or the
/// configured internet relay when that list is empty (remote access off, or
/// the local relay still coming up — a code must still be showable).
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
            RelayEndpointKind.internet => PairingRelayKind.internet,
          },
        ),
    ];
  }
  final settings = ref.watch(settingsControllerProvider);
  return [
    PairingRelayEndpoint(
      label: 'Internet',
      url: resolveRelayUri(settings.remoteRelayUrl),
      kind: PairingRelayKind.internet,
    ),
  ];
});
