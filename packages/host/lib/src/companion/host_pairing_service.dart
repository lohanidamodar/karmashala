import 'dart:async';

import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/devices.dart';

/// Runs the pairing ceremony for a host that has no screen to show a QR on.
///
/// The desktop shows a code; a box prints one. Nothing else differs — the same
/// [HostPairingSession], the same sealed round-trip, the same row — which is
/// what makes a session host a peer a phone pairs with rather than a machine
/// behind somebody else's desktop.
///
/// **The row goes in this host's own store.** That is what the store is for: a
/// box keeps its pairings the way the desktop keeps its own, so pairing with
/// one machine says nothing about any other.
class HostPairingService {
  HostPairingService({
    required this.database,
    required this.hostName,
    required this.hostId,
    this.ttl = kPairingTtl,
    DateTime Function()? clock,
  }) : _devices = PairedDeviceDao(database),
       _now = clock ?? DateTime.now;

  final AppDatabase database;
  final String hostName;

  /// This machine's own id, stable across restarts — the phone pins it, so a
  /// host that minted a new one each time would look like a different machine.
  final DeviceId hostId;

  final Duration ttl;
  final PairedDeviceDao _devices;
  final DateTime Function() _now;

  /// Everything this host is willing to grant. A phone is granted what the
  /// person offers it here, exactly as on the desktop; nothing widens later.
  static CapabilitySet get everything => CapabilitySet.all;

  /// Opens one pairing window. The caller shows [PairingCode.encode] of the
  /// payload's typed secret, attaches the transports it is listening on, and
  /// awaits [HostPairingSession.done].
  ///
  /// [relay] is where a phone that cannot reach this machine directly would
  /// meet it. A box with its own address usually needs none, and says so by
  /// passing its own address — the payload carries a rendezvous either way, so
  /// the phone is never left guessing which it is.
  Future<HostPairingSession> open({
    required Uri relay,
    CapabilitySet? grant,
    List<Uri> relays = const [],
    String? relayUrl,
  }) async {
    final payload = await PairingPayload.generateWithCode(
      relay: relay,
      hostId: hostId,
      capabilities: grant ?? everything,
      relays: relays,
    );
    return HostPairingSession(
      payload: payload,
      hostName: hostName,
      ttl: ttl,
      now: _now,
      // Persisted only once both ends have proved they hold the secret — the
      // session does the proving, this only writes what it hands over.
      // [relayUrl] is the route this phone was offered: null is "dial this
      // machine", and a URL is where `serve` will wait for it from now on.
      persist: (device) async => _devices.insert(
        relayUrl == null ? device : device.copyWith(relayUrl: relayUrl),
      ),
    );
  }

  /// Moves a phone's row to the next generation it will be recognised from, so
  /// a restarted host still finds a phone that has been back since pairing.
  void advance(String deviceId, int generation) =>
      _devices.updateGeneration(deviceId, generation);

  /// Every phone this host has paired with, newest first. What `serve` reads to
  /// know whose key a link is sealed with and what that phone was granted.
  List<PairedDevice> paired() => _devices.getActive();
}
