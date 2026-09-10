/// The companion's leg of the direct path: listen for the host's beacon, offer
/// dial candidates, and remember which hosts just failed so the LAN attempt
/// never holds the relay hostage. The beacon is cleartext and carries no
/// identity — the sealed channel is the only proof a host is the right one.
library;

import 'dart:async';
import 'dart:io';

import '../transport/lan_beacon.dart';
import '../transport/lan_transport.dart';
import '../transport/remote_transport.dart';

/// Holds the platform's multicast lock while discovery listens. Android drops
/// multicast datagrams without one; the default [NoopMulticastLock] is best
/// effort by design, because a silent beacon costs only the direct path.
abstract interface class MulticastLockHolder {
  Future<void> acquire();
  Future<void> release();
}

/// The default holder: does nothing, fails never.
class NoopMulticastLock implements MulticastLockHolder {
  const NoopMulticastLock();

  @override
  Future<void> acquire() async {}

  @override
  Future<void> release() async {}
}

/// Builds the transport that dials one discovered host — a seam for tests.
typedef LanDialerFn = RemoteTransport Function(String host, int port);

/// How long a LAN attempt may take — dial plus sealed hello — before the
/// relay is dialled instead (design §3: direct first, relay fallback).
const Duration kLanAttemptTimeout = Duration(seconds: 2);

/// How long a host that failed a LAN attempt is left alone before the beacon
/// may talk the companion into trying it again.
const Duration kLanRetryCooldown = Duration(minutes: 2);

/// Watches the LAN for Karmashala hosts on behalf of the companion gateway.
/// Best-effort: a platform where multicast cannot be joined leaves the scout
/// inert ([isListening] false) and the gateway on the relay.
class LanPathScout {
  LanPathScout({
    InternetAddress? group,
    this.beaconPort = kLanBeaconPort,
    MulticastLockHolder? lock,
    LanDialerFn? dialer,
    this.attemptTimeout = kLanAttemptTimeout,
    this.retryCooldown = kLanRetryCooldown,
    DateTime Function()? now,
    this.onLog,
  }) : group = group ?? kLanBeaconGroup,
       lock = lock ?? const NoopMulticastLock(),
       // ignore: prefer_initializing_formals — private field, named for callers.
       _dialer = dialer,
       _now = now ?? DateTime.now;

  final InternetAddress group;
  final int beaconPort;
  final MulticastLockHolder lock;
  final Duration attemptTimeout;
  final Duration retryCooldown;
  final void Function(String message)? onLog;

  final LanDialerFn? _dialer;
  final DateTime Function() _now;

  LanDiscovery? _discovery;
  StreamSubscription<DiscoveredHost>? _adverts;
  bool _started = false;

  /// Hosts that failed a sealed attempt recently, by [keyOf], with when.
  final Map<String, DateTime> _failures = {};

  final StreamController<DiscoveredHost> _sightings =
      StreamController<DiscoveredHost>.broadcast();

  /// Every advert as it arrives — what the gateway uses to upgrade a relay
  /// link to the LAN. Cooldown filtering is the caller's, via [inCooldown].
  Stream<DiscoveredHost> get sightings => _sightings.stream;

  bool get isListening => _discovery != null;

  /// Joins the beacon group. Never throws: a network that refuses multicast
  /// leaves the scout inert and the relay untouched.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      await lock.acquire();
    } on Object catch (error) {
      onLog?.call('multicast lock refused: $error');
    }
    try {
      final discovery = await LanDiscovery.start(
        group: group,
        beaconPort: beaconPort,
        // One clock for the whole scout: the same [_now] that decides a
        // cooldown decides whether a host has gone quiet.
        now: _now,
      );
      _discovery = discovery;
      _adverts = discovery.adverts.listen((host) {
        if (!_sightings.isClosed) _sightings.add(host);
      });
    } on Object catch (error) {
      onLog?.call('lan discovery unavailable: $error');
    }
  }

  /// Hosts worth dialling right now: heard recently, not in cooldown,
  /// newest sighting first.
  List<DiscoveredHost> get candidates {
    final discovery = _discovery;
    if (discovery == null) return const [];
    final fresh = [
      for (final host in discovery.hosts)
        if (!inCooldown(host)) host,
    ]..sort((a, b) => b.seenAt.compareTo(a.seenAt));
    return fresh;
  }

  /// One address:port — the identity a failure is remembered under. Never
  /// the advert's tag: the tag is a per-boot random label, not an identity.
  String keyOf(DiscoveredHost host) => '${host.address.address}:${host.port}';

  bool inCooldown(DiscoveredHost host) {
    final failedAt = _failures[keyOf(host)];
    if (failedAt == null) return false;
    if (_now().difference(failedAt) < retryCooldown) return true;
    _failures.remove(keyOf(host));
    return false;
  }

  /// A dial or sealed hello against [host] failed: leave it alone for
  /// [retryCooldown] so the beacon cannot wedge the gateway in a LAN loop.
  void noteFailure(DiscoveredHost host) => _failures[keyOf(host)] = _now();

  /// The sealed channel proved [host]; forget any grudge.
  void noteSuccess(DiscoveredHost host) => _failures.remove(keyOf(host));

  /// Dials [host]'s advertised TCP port. Proof comes later, from the sealed
  /// hello — this transport is a hint being tested, nothing more.
  RemoteTransport dial(DiscoveredHost host) {
    final dialer = _dialer;
    if (dialer != null) return dialer(host.address.address, host.port);
    return LanTransport.dial(
      host: host.address.address,
      port: host.port,
      connectTimeout: attemptTimeout,
      onLog: onLog,
    );
  }

  Future<void> stop() async {
    _started = false;
    await _adverts?.cancel();
    _adverts = null;
    final discovery = _discovery;
    _discovery = null;
    if (discovery != null) {
      try {
        await discovery.stop();
      } on Object catch (error) {
        onLog?.call('lan discovery stop failed: $error');
      }
    }
    try {
      await lock.release();
    } on Object catch (error) {
      onLog?.call('multicast lock release failed: $error');
    }
    if (!_sightings.isClosed) await _sightings.close();
  }
}
