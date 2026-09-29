/// A desktop app as the client of a server on another machine (slice 5e):
/// the phone's pairing record and sealed channel, switched to the host
/// protocol with `host.attach`, over the server's LAN listener or a relay.
library;

import 'dart:async';
import 'dart:io' show InternetAddress;
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:karmashala_host_protocol/host_access.dart' show RemoteChannel;

import '../domain/remote_payloads.dart' show RemoteHostStatus;
import '../pairing/pairing_wire.dart';
import '../protocol.dart';
import '../transport/key_schedule.dart';
import '../transport/lan_beacon.dart' show DiscoveredHost, LanAdvert;
import '../transport/lan_transport.dart';
import '../transport/relay_transport.dart';
import '../transport/remote_transport.dart';
import '../transport/sealed_channel.dart';
import '../transport/sealed_host_link.dart';
import 'companion_client.dart'
    show RelayTransportFactoryFn, kCompanionProbeWindow;
import 'companion_store.dart';
import 'lan_path.dart' show LanDialerFn, LanPathScout;
import 'relay_candidates.dart';
import 'route_pin.dart';

/// Why a desktop could not reach its server; [message] is safe to show.
class DesktopConnectException implements Exception {
  const DesktopConnectException(this.message, {this.refused = false});

  final String message;

  /// The server answered and said no (the pairing grants no desktop): no
  /// other route or generation will say otherwise.
  final bool refused;

  @override
  String toString() => message;
}

/// Opens one sealed host link over [transport] at [generation]: the link
/// hello, the server's `host.status`, then `host.attach`. The transport is
/// closed with the link, and a transport that drops ends the link. The link's
/// `capabilities` are what that status granted, as of this link only.
///
/// [onHostStatus] hears the server's `host.status` — where it can be met
/// (relays, LAN address) — for the dialer to fold into the saved record.
Future<SealedHostLink> connectDesktopLink({
  required CompanionPairing pairing,
  required RemoteTransport transport,
  required int generation,
  Duration timeout = const Duration(seconds: 8),
  void Function(RemoteHostStatus status)? onHostStatus,
}) async {
  final key = SecretKeyData(pairing.deviceKey);
  final channel = await SealedChannel.forDevice(
    deviceKey: key,
    role: ChannelRole.companion,
    generation: generation,
  );
  SealedHostLink? link;
  // An older server's status carries no grants: the pairing's stand in.
  var granted = pairing.capabilities;
  final greeted = Completer<void>();
  final attached = Completer<void>();
  var chain = Future<void>.value();
  var connected = false;

  final frames = transport.frames.listen((frame) {
    chain = chain.then((_) async {
      final SealedFrame opened;
      try {
        opened = await channel.unseal(frame);
      } on SealedChannelException catch (error) {
        link?.close('a frame would not open: $error');
        return;
      }
      final current = link;
      if (current != null) {
        current.receive(opened);
        return;
      }
      final Envelope envelope;
      try {
        envelope = Envelope.fromBytes(
          opened.plaintext,
          accept: VersionRange.any,
        );
      } on ProtocolException {
        return;
      }
      switch (envelope.knownType) {
        case FrameType.hostStatus when !greeted.isCompleted:
          try {
            final caps = RemoteHostStatus.fromJson(
              envelope.payload,
            ).capabilities;
            if (caps != null) granted = caps;
          } on Object {
            // A status this build cannot read still greets.
          }
          _hearHostStatus(envelope.payload, onHostStatus);
          greeted.complete();
        case FrameType.result when envelope.id == _attachId:
          link = SealedHostLink(
            channel: channel,
            sendSealed: transport.send,
            nextReceiveSequence: opened.sequence + 1,
            capabilities: granted,
          );
          if (!attached.isCompleted) attached.complete();
        case FrameType.error when envelope.id == _attachId:
          final message = envelope.payload['message'];
          if (!attached.isCompleted) {
            attached.completeError(
              DesktopConnectException(
                message is String ? message : 'the server refused',
                refused: true,
              ),
            );
          }
        default:
          break;
      }
    });
  });
  final states = transport.states.listen((state) {
    if (state == TransportState.connected) {
      connected = true;
      return;
    }
    if (connected &&
        (state == TransportState.disconnected ||
            state == TransportState.closed)) {
      link?.close('the connection dropped');
    }
  });

  Future<SealedHostLink> give(Object error) async {
    await frames.cancel();
    await states.cancel();
    await transport.close();
    throw error;
  }

  try {
    transport.send(LinkHello(await rendezvousFor(key, generation)).encode());
    await greeted.future.timeout(timeout);
    final envelope = Envelope.of(
      FrameType.hostAttach,
      seq: channel.nextSendSequence,
      id: _attachId,
    );
    transport.send(await channel.seal(envelope.toBytes()));
    await attached.future.timeout(timeout);
  } on TimeoutException {
    return give(
      DesktopConnectException(
        connected
            ? 'the server did not answer there'
            : 'nothing could be reached there',
      ),
    );
  } on DesktopConnectException catch (error) {
    return give(error);
  } on TransportException catch (error) {
    return give(DesktopConnectException(error.message));
  }
  final opened = link!;
  unawaited(
    opened.done.then((_) async {
      await frames.cancel();
      await states.cancel();
      await transport.close();
    }),
  );
  return opened;
}

const String _attachId = 'attach';

/// Hands [payload] to [listener] decoded. A status this build cannot read
/// costs its routes, never the link.
void _hearHostStatus(
  Map<String, Object?> payload,
  void Function(RemoteHostStatus status)? listener,
) {
  if (listener == null) return;
  final RemoteHostStatus status;
  try {
    status = RemoteHostStatus.fromJson(payload);
  } on ProtocolException {
    return;
  }
  listener(status);
}

/// Dials a paired server in the phone's order
/// (`remote_companion_gateway_dial.dart`), minus the promotion that needs a
/// live link to promote (Stage 0 step 18):
///
/// 1. the address typed at pairing ([CompanionPairing.directEndpoint]);
/// 2. the route pin, when set — a pin is "only", never "prefer";
/// 3. up to three fresh [LanPathScout] sightings;
/// 4. the LAN address the server announced in its last `host.status`;
/// 5. the relays by [orderRelayCandidates] — last known good first, cooling
///    ones skipped — with each outcome stamped on the record.
///
/// Each route walks a few generations forward, but only once something took
/// the socket: nobody home is one dial. The counter moves on after each
/// link, so the next one starts on a fresh generation. The dialer itself
/// does not loop; the data client's and panes' redial delays do.
class DesktopServerDialer {
  DesktopServerDialer({
    required this.store,
    LanDialerFn? lanDialer,
    RelayTransportFactoryFn? relayFactory,
    this.timeout = const Duration(seconds: 6),
    this.lanTimeout = kDesktopLanAttemptTimeout,
    this.scout,
    this.onLog,
    DateTime Function()? now,
  }) : _lanDialer = lanDialer ?? _dialLan,
       _relayFactory = relayFactory ?? _dialRelay,
       _now = now ?? DateTime.now;

  final CompanionStore store;

  /// How long the direct address, a relay or a pinned LAN route may take to
  /// answer the hello and the attach.
  final Duration timeout;

  /// The same for a LAN sighting or hint that is not pinned: a stale advert,
  /// or another server's, must not hold up the relay behind it.
  final Duration lanTimeout;

  /// Beacon listening, owned with this dialer by `RemoteServerAccess`. Null
  /// dials no sightings, as before.
  final LanPathScout? scout;

  final void Function(String message)? onLog;

  final LanDialerFn _lanDialer;
  final RelayTransportFactoryFn _relayFactory;
  final DateTime Function() _now;

  Future<void>? _scoutStarting;
  DateTime? _scoutStartedAt;
  bool _closed = false;

  static RemoteTransport _dialLan(String host, int port) =>
      LanTransport.dial(host: host, port: port);

  static RemoteTransport _dialRelay(Uri relay, RendezvousId rendezvous) =>
      RelayTransport.connect(relay: relay, rendezvous: rendezvous);

  /// Starts beacon listening, once. Called as soon as a remote machine is in
  /// use, so sightings have gathered by the first dial. Never throws: a
  /// network that refuses multicast leaves the scout inert.
  Future<void> startScouting() {
    final scout = this.scout;
    if (scout == null || _closed) return Future<void>.value();
    return _scoutStarting ??= () {
      _scoutStartedAt = _now();
      return scout.start();
    }();
  }

  /// Stops beacon listening for good: this machine is no longer in use.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final starting = _scoutStarting;
    if (starting == null) return;
    await starting;
    await scout?.stop();
  }

  /// Throws [DesktopConnectException] naming what each route answered.
  Future<SealedHostLink> dial(CompanionPairing pairing) async {
    final notes = <String>[];
    final name = pairing.hostName.isEmpty ? 'the server' : pairing.hostName;
    String said() => notes.isEmpty ? '' : ' (${notes.toSet().join('; ')})';

    // 1. The address typed at pairing: a server with its own address is
    // never worth a detour through a relay.
    final direct = parseEndpoint(pairing.directEndpoint);
    if (direct != null) {
      final link = await _attempt(
        pairing,
        notes,
        label: '${direct.$1}:${direct.$2}',
        path: 'direct',
        timeout: timeout,
        open: (_) async => _lanDialer(direct.$1, direct.$2),
      );
      if (link != null) return link;
    }

    // 2. A person's pin: one route and nothing else. A pinned route that
    // does not answer is said, never quietly swapped for another.
    final pin = pairing.pin;
    final pinnedRelay = pin.kind == CompanionRouteKind.relay ? pin.relay : null;
    if (pinnedRelay != null) {
      final link = await _attemptRelay(pairing, pinnedRelay, notes);
      if (link != null) return link;
      throw DesktopConnectException(
        '$name is pinned to the relay at ${pinnedRelay.host}, and it is not '
        'answering there${said()}.',
      );
    }
    final pinnedLan = pin.kind == CompanionRouteKind.lan;

    // 3. Fresh beacon sightings. The beacon carries no identity, so one may
    // be another server's: the sealed hello decides, and a wrong one cools
    // down for two minutes.
    final tried = <String>{if (direct != null) '${direct.$1}:${direct.$2}'};
    final scout = this.scout;
    if (scout != null && !_closed) {
      await startScouting();
      await _awaitFirstSighting(scout);
      for (final host in scout.candidates.take(3).toList()) {
        if (!tried.add(scout.keyOf(host))) continue;
        final link = await _attemptLan(pairing, notes, host, pinned: pinnedLan);
        if (link != null) return link;
      }
    }

    // 4. The LAN address the server announced last time. Unlike the phone,
    // tried even after sightings failed, unless one of them was this very
    // address: another server's beacon on this network (the owner's own, on
    // this PC) must not hide this one's hint.
    final hinted = _lanHintHost(pairing);
    if (hinted != null &&
        tried.add('${hinted.address.address}:${hinted.port}')) {
      // The cooldown exists so a dead address does not delay the relay
      // behind it; a LAN pin has no relay behind it.
      final cooling = !pinnedLan && scout != null && scout.inCooldown(hinted);
      if (!cooling) {
        final link = await _attemptLan(
          pairing,
          notes,
          hinted,
          pinned: pinnedLan,
        );
        if (link != null) return link;
      }
    }

    if (pinnedLan) {
      throw DesktopConnectException(
        '$name is pinned to this network (LAN), and it is not answering '
        'here${said()}.',
      );
    }

    // 5. The relays, last known good first.
    for (final url in _relayOrder(pairing)) {
      final link = await _attemptRelay(pairing, url, notes);
      if (link != null) return link;
    }
    throw DesktopConnectException('Could not reach $name${said()}.');
  }

  /// A scout that has only just started has heard nothing yet: give the
  /// first beacon one interval to arrive, once per process, rather than
  /// leaving a server on this network to the relay at every launch.
  Future<void> _awaitFirstSighting(LanPathScout scout) async {
    final started = _scoutStartedAt;
    if (started == null || !scout.isListening) return;
    if (scout.candidates.isNotEmpty) return;
    final left = started.add(kDesktopFirstSightingWait).difference(_now());
    if (left <= Duration.zero) return;
    try {
      await scout.sightings.first.timeout(left);
    } on Object {
      // Nothing heard in time, or the scout stopped: the next route carries on.
    }
  }

  Future<SealedHostLink?> _attemptLan(
    CompanionPairing pairing,
    List<String> notes,
    DiscoveredHost host, {
    required bool pinned,
  }) async {
    final scout = this.scout;
    final link = await _attempt(
      pairing,
      notes,
      label: '${host.address.address}:${host.port}',
      path: host.tag == _kLanHintTag ? 'lan (announced address)' : 'lan',
      timeout: pinned ? timeout : lanTimeout,
      open: (_) async => scout != null
          ? scout.dial(host)
          : _lanDialer(host.address.address, host.port),
    );
    if (scout != null) {
      if (link == null) {
        scout.noteFailure(host);
      } else {
        scout.noteSuccess(host);
      }
    }
    return link;
  }

  Future<SealedHostLink?> _attemptRelay(
    CompanionPairing pairing,
    Uri url,
    List<String> notes,
  ) async {
    final key = SecretKeyData(pairing.deviceKey);
    final link = await _attempt(
      pairing,
      notes,
      // The host alone: a relay's URL can carry its access token.
      label: 'relay ${url.host}',
      path: 'relay',
      timeout: timeout,
      relay: url,
      open: (generation) async =>
          _relayFactory(url, await rendezvousFor(key, generation)),
    );
    if (link == null) await _noteRelayFailure(pairing, url);
    return link;
  }

  /// One route, walked across the generation window. Only a route that took
  /// the socket is asked again one generation later: a server whose counter
  /// moved on hangs up on a rendezvous it no longer holds.
  Future<SealedHostLink?> _attempt(
    CompanionPairing pairing,
    List<String> notes, {
    required String label,
    required String path,
    required Duration timeout,
    required Future<RemoteTransport> Function(int generation) open,
    Uri? relay,
  }) async {
    for (var probe = 0; probe < kCompanionProbeWindow; probe++) {
      final generation = pairing.generation + probe;
      onLog?.call('dialling ${pairing.hostName} over $path at $label');
      final transport = await open(generation);
      var socketOpened = false;
      final watching = transport.states.listen((state) {
        if (state == TransportState.connected) socketOpened = true;
      });
      RemoteHostStatus? status;
      try {
        final link = await connectDesktopLink(
          pairing: pairing,
          transport: transport,
          generation: generation,
          timeout: timeout,
          onHostStatus: (announced) => status = announced,
        );
        onLog?.call('connected to ${pairing.hostName} over $path at $label');
        await _settle(pairing, generation, status, relay: relay);
        return link;
      } on DesktopConnectException catch (error) {
        if (error.refused) rethrow;
        notes.add('$label: ${error.message}');
        onLog?.call('$path attempt at $label failed: ${error.message}');
        if (!socketOpened) break;
      } finally {
        await watching.cancel();
      }
    }
    return null;
  }

  /// The server's announced LAN address as a sighting to dial. A hint, not an
  /// identity: DHCP may have moved it, and only the sealed hello decides.
  DiscoveredHost? _lanHintHost(CompanionPairing pairing) {
    final hint = parseLanHint(pairing.lanHint);
    if (hint == null) return null;
    final address = InternetAddress.tryParse(hint.host);
    if (address == null) return null;
    return DiscoveredHost(
      address: address,
      advert: LanAdvert(port: hint.port, tag: _kLanHintTag),
      seenAt: _now(),
    );
  }

  /// The relays to try, in order: the record's candidates by health, then the
  /// relay it was paired at. A pairing made without one names
  /// `invalid.local`, which is nowhere.
  List<Uri> _relayOrder(CompanionPairing pairing) => [
    for (final url in orderRelayCandidates(
      pairing.candidates,
      fallback: pairing.relay,
      now: _now(),
    ))
      if (url.host != 'invalid.local') url,
  ];

  /// After a link: the counter moves on, and what the server just announced
  /// in `host.status` — its relays, health carried over, and its LAN address
  /// — is folded into the saved record, as the phone does. Read from the
  /// store rather than [pairing], so a write in between is kept.
  Future<void> _settle(
    CompanionPairing pairing,
    int used,
    RemoteHostStatus? status, {
    Uri? relay,
  }) async {
    final at = _now();
    try {
      await CompanionConnections.mutate(store, (all) {
        final saved = all.byHost(pairing.hostId.value) ?? pairing;
        var candidates = mergeRelayCandidates(
          saved.candidates,
          status?.relays ?? const [],
        );
        if (relay != null) {
          final key = relay.toString();
          candidates = [
            for (final candidate in candidates)
              candidate.key == key ? candidate.succeededAt(at) : candidate,
            if (!candidates.any((candidate) => candidate.key == key))
              RelayCandidate(url: relay).succeededAt(at),
          ];
        }
        all.upsert(
          saved.copyWith(
            // Never backwards: another dial may have moved it further.
            generation: used + 1 > saved.generation ? used + 1 : null,
            lastConnectedAt: at.toUtc(),
            candidates: candidates,
            lanHint: status?.lanHint,
            relay: relay,
          ),
        );
        return all;
      });
    } on Object catch (error) {
      // A counter that did not stick costs a probe forward next time.
      onLog?.call('saving the link to ${pairing.hostName} failed: $error');
    }
  }

  /// Stamps a relay that did not answer, so the next dial skips it while it
  /// cools. Best effort: a refused write costs ordering, never a link.
  Future<void> _noteRelayFailure(CompanionPairing pairing, Uri url) async {
    final key = url.toString();
    final at = _now();
    try {
      await CompanionConnections.mutate(store, (all) {
        final saved = all.byHost(pairing.hostId.value);
        // The relay paired at is tried without being saved; it earns a place
        // in the set only by working.
        if (saved == null ||
            !saved.candidates.any((candidate) => candidate.key == key)) {
          return all;
        }
        all.upsert(
          saved.copyWith(
            candidates: [
              for (final candidate in saved.candidates)
                candidate.key == key ? candidate.failedAt(at) : candidate,
            ],
          ),
        );
        return all;
      });
    } on Object catch (error) {
      onLog?.call('relay outcome stamp failed: $error');
    }
  }
}

/// The tag a LAN hint is dialled under, so the log tells it from a beacon.
const String _kLanHintTag = 'hint';

/// How long a LAN sighting or hint that is not pinned may take — dial, sealed
/// hello and attach — before the next route is tried.
const Duration kDesktopLanAttemptTimeout = Duration(seconds: 3);

/// How long after beacon listening starts the first dial waits for a first
/// sighting: one beacon interval (`kLanBeaconInterval`) and a little.
const Duration kDesktopFirstSightingWait = Duration(milliseconds: 2500);

/// `host:port` as a pair, or null when [text] is not one.
(String, int)? parseEndpoint(String? text) {
  if (text == null || text.isEmpty) return null;
  final colon = text.lastIndexOf(':');
  if (colon <= 0) return null;
  final port = int.tryParse(text.substring(colon + 1));
  if (port == null || port <= 0 || port > 65535) return null;
  return (text.substring(0, colon), port);
}

/// A sealed host link as the byte channel a host-protocol link runs over.
class SealedHostChannel implements RemoteChannel {
  SealedHostChannel(this.link);

  final SealedHostLink link;

  @override
  Stream<Uint8List> get stdout => link.incoming;

  @override
  Stream<Uint8List> get stderr => const Stream<Uint8List>.empty();

  @override
  void add(Uint8List bytes) => link.add(bytes);

  @override
  Future<int> get exitCode => link.done.then((_) => 0);

  @override
  Future<void> close() async => link.close('the client hung up');
}
