/// The relay choices the pairing dialog offers, as tabs. One entry — the usual
/// case — renders no tab chrome at all; the shape is pinned by a test.
library;

import 'package:riverpod/riverpod.dart';

import '../application/remote_access_controller.dart';
import '../application/remote_access_settings.dart';
import '../application/ssh_relays.dart';

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

/// The endpoints the dialog shows, one per relay the server is serving: its
/// own LAN relay first (it always works on a shared network), then the
/// person's own boxes, then the internet relay. **Empty is real**: with every
/// relay off, no code could be redeemed. With remote access off, the internet
/// relay is offered — switching it on is part of pairing.
final pairingRelayEndpointsProvider = Provider<List<PairingRelayEndpoint>>((
  ref,
) {
  final access = ref.watch(remoteAccessSettingsProvider);
  if (!access.enabled) {
    return [
      PairingRelayEndpoint(
        label: 'Internet',
        url: hostedRelayOf(access),
        kind: PairingRelayKind.internet,
      ),
    ];
  }
  final local = access.localRelayReport;
  final localUrl = local.url;
  return [
    // Where the server's relay listens now; the server itself decides where a
    // local pairing is met.
    if (access.localRelay && local.running && localUrl != null)
      PairingRelayEndpoint(
        label: 'Local network',
        url: localUrl,
        kind: PairingRelayKind.local,
      ),
    // The person's own boxes before somebody else's relay.
    for (final entry in ref.watch(sshRelaysProvider))
      if (entry.enabled)
        PairingRelayEndpoint(
          label: entry.hostName,
          url: entry.url,
          kind: PairingRelayKind.sshHost,
        ),
    if (access.relayEnabled)
      PairingRelayEndpoint(
        label: 'Internet',
        url: hostedRelayOf(access),
        kind: PairingRelayKind.internet,
      ),
  ];
});
