part of '../desktop_client.dart';

/// Dials a paired server in the phone's order
/// (`remote_companion_gateway_dial.dart`); the promotion off a relay is the
/// live link's own (Stage 0 step 18, see [dial]):
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

  /// Beacon listening stops and the multicast lock is let go, until
  /// [restartScouting]: a phone in the background.
  Future<void> pauseScouting() async {
    final scout = this.scout;
    final starting = _scoutStarting;
    if (scout == null || _closed || starting == null) return;
    await starting;
    await scout.pause();
  }

  /// Listens afresh, on the interfaces there are now — after [pauseScouting]
  /// or a network change — and the next dial waits for a first sighting
  /// again, since the old ones were heard on another network.
  Future<void> restartScouting() async {
    final scout = this.scout;
    if (scout == null || _closed) return;
    final starting = _scoutStarting;
    if (starting == null) return startScouting();
    await starting;
    _scoutStartedAt = _now();
    await scout.restart();
  }

  final StreamController<void> _proofs = StreamController<void>.broadcast();

  /// Every live link this dialer opened proves itself now rather than at its
  /// next keepalive, and a held one tries its routes now rather than after
  /// its backoff: the app came back, or the network under it changed.
  void proveLinks() {
    if (!_closed && !_proofs.isClosed) _proofs.add(null);
  }

  /// Stops beacon listening for good: this machine is no longer in use.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _proofs.close();
    final starting = _scoutStarting;
    if (starting == null) return;
    await starting;
    await scout?.stop();
  }

  /// Throws [DesktopConnectException] naming what each route answered.
  ///
  /// With [resumeOffered], a link whose socket drops is resumed rather than
  /// ended (Stage 0 step 17) when it answers true at the drop — the server
  /// announced `link.resume`. The resume walks the same routes as this dial,
  /// at the link's own generation, within [kHostLinkResumeGrace].
  ///
  /// With [promoteOffered] as well (Stage 0 step 18), a link that came up on
  /// a relay is moved onto a LAN route — a beacon sighting, the announced LAN
  /// address or the typed one — with a resume, before the relay is let go,
  /// when the server announced `link.promote`. With [keepaliveOffered], an
  /// idle link pings a server that announced `link.keepalive`, and a silent
  /// one is resumed like a dropped one.
  Future<SealedHostLink> dial(
    CompanionPairing pairing, {
    bool Function()? resumeOffered,
    void Function(bool held)? onHeld,
    bool Function()? promoteOffered,
    bool Function()? keepaliveOffered,
  }) async {
    final notes = <String>[];
    final name = pairing.hostName.isEmpty ? 'the server' : pairing.hostName;
    String said() => notes.isEmpty ? '' : ' (${notes.toSet().join('; ')})';
    final scout = this.scout;
    final resume = resumeOffered == null
        ? null
        : DesktopLinkResume(
            offered: resumeOffered,
            routes: (generation) => _resumeRoutes(pairing, generation),
            hostName: name,
            onLog: onLog,
            onHeld: onHeld,
            proofs: _proofs.stream,
            promoteOffered: promoteOffered,
            keepaliveOffered: keepaliveOffered,
            lanRoutes: promoteOffered == null
                ? null
                : (generation) =>
                      _resumeRoutes(pairing, generation, promotion: true),
            lanChances: promoteOffered == null || scout == null
                ? null
                : scout.sightings
                      .where((host) => !scout.inCooldown(host))
                      .map<void>((_) {}),
          );

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
        resume: resume,
      );
      if (link != null) return link;
    }

    // 2. A person's pin: one route and nothing else. A pinned route that
    // does not answer is said, never quietly swapped for another.
    final pin = pairing.pin;
    final pinnedRelay = pin.kind == CompanionRouteKind.relay ? pin.relay : null;
    if (pinnedRelay != null) {
      final link = await _attemptRelay(
        pairing,
        pinnedRelay,
        notes,
        resume: resume,
      );
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
    if (scout != null && !_closed) {
      await startScouting();
      await _awaitFirstSighting(scout);
      for (final host in scout.candidates.take(3).toList()) {
        if (!tried.add(scout.keyOf(host))) continue;
        final link = await _attemptLan(
          pairing,
          notes,
          host,
          pinned: pinnedLan,
          resume: resume,
        );
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
          resume: resume,
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
      final link = await _attemptRelay(pairing, url, notes, resume: resume);
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

  /// The routes a resume walks (Stage 0 step 17), in [dial]'s order and
  /// under its pin, but all at the link's own [generation] — a resume never
  /// probes forward — and without waiting for a first beacon. Read from the
  /// store, so relays and a LAN address learned since the dial are in it.
  ///
  /// For a [promotion] (Stage 0 step 18): the same routes minus every relay,
  /// and none at all under a relay pin — a pin is "only".
  Future<List<DesktopResumeRoute>> _resumeRoutes(
    CompanionPairing pairing,
    int generation, {
    bool promotion = false,
  }) async {
    var saved = pairing;
    try {
      saved =
          (await CompanionConnections.load(
            store,
          )).byHost(pairing.hostId.value) ??
          pairing;
    } on Object {
      // The record as dialled still names every route it had.
    }
    final key = SecretKeyData(saved.deviceKey);
    final routes = <DesktopResumeRoute>[];
    final direct = parseEndpoint(saved.directEndpoint);
    if (direct != null) {
      routes.add(
        DesktopResumeRoute(
          path: 'direct',
          label: '${direct.$1}:${direct.$2}',
          timeout: timeout,
          open: () async => _lanDialer(direct.$1, direct.$2),
          address: direct.$1,
        ),
      );
    }
    DesktopResumeRoute relayRoute(Uri url) => DesktopResumeRoute(
      path: 'relay',
      // The host alone: a relay's URL can carry its access token.
      label: 'relay ${url.host}',
      timeout: timeout,
      open: () async =>
          _relayFactory(url, await rendezvousFor(key, generation)),
      noted: (answered) {
        if (!answered) unawaited(_noteRelayFailure(saved, url));
      },
      relayHost: url.host,
    );
    final pin = saved.pin;
    final pinnedRelay = pin.kind == CompanionRouteKind.relay ? pin.relay : null;
    if (pinnedRelay != null) {
      return promotion ? const [] : [...routes, relayRoute(pinnedRelay)];
    }
    final pinnedLan = pin.kind == CompanionRouteKind.lan;
    final scout = this.scout;
    DesktopResumeRoute lanRoute(DiscoveredHost host) => DesktopResumeRoute(
      path: host.tag == _kLanHintTag ? 'lan (announced address)' : 'lan',
      label: '${host.address.address}:${host.port}',
      address: host.address.address,
      timeout: pinnedLan ? timeout : lanTimeout,
      open: () async => scout != null
          ? scout.dial(host)
          : _lanDialer(host.address.address, host.port),
      noted: scout == null
          ? null
          : (answered) {
              if (answered) {
                scout.noteSuccess(host);
              } else {
                scout.noteFailure(host);
              }
            },
    );
    final tried = <String>{if (direct != null) '${direct.$1}:${direct.$2}'};
    if (scout != null && !_closed) {
      for (final host in scout.candidates.take(3).toList()) {
        if (tried.add(scout.keyOf(host))) routes.add(lanRoute(host));
      }
    }
    final hinted = _lanHintHost(saved);
    if (hinted != null &&
        tried.add('${hinted.address.address}:${hinted.port}') &&
        (pinnedLan || scout == null || !scout.inCooldown(hinted))) {
      routes.add(lanRoute(hinted));
    }
    if (pinnedLan || promotion) return routes;
    return [...routes, for (final url in _relayOrder(saved)) relayRoute(url)];
  }

  Future<SealedHostLink?> _attemptLan(
    CompanionPairing pairing,
    List<String> notes,
    DiscoveredHost host, {
    required bool pinned,
    DesktopLinkResume? resume,
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
      resume: resume,
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
    List<String> notes, {
    DesktopLinkResume? resume,
  }) async {
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
      resume: resume,
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
    DesktopLinkResume? resume,
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
          resume: resume,
          relayHost: relay?.host,
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
