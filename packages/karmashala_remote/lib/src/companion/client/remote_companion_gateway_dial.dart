part of 'remote_companion_gateway.dart';

// The paths one dial tries, in order: the peer's own address when the pairing
// has one, every fresh LAN candidate, the host's own LAN hint, then the relays
// newest-known-good first. First success wins; each loser is torn down before
// the next is tried.

/// Why a directly-paired box is not connected, and the one remedy there is:
/// the route is chosen on the desktop, so that is where it is changed.
String _directUnreachableTrouble(String? endpoint) =>
    '${endpoint ?? 'This machine'} did not answer. If it is no longer '
    "reachable from here, pair it again from the desktop and choose 'Hosted "
    "relay'.";

extension _GatewayDial on RemoteCompanionGateway {
  /// The dial order: every fresh LAN candidate, the host's own LAN hint, the
  /// last relay that worked, the rest of the saved set (skipping any still
  /// cooling), then the configured default. First success wins and is
  /// remembered; only one dial is ever in flight. Null when nobody answered.
  Future<CompanionClient?> _dialAnyPath() async {
    // First, and before any discovery: a session host on a box is reached at
    // the address the person typed when they paired. It is never on the
    // beacon — that is a LAN broadcast and the box is on the internet — and
    // going through a relay to reach a machine with its own address would be
    // paying a detour for nothing.
    final direct = await _dialDirect();
    if (direct != null) return direct;
    if (_abandonDial) return null;

    // A box is reached by the one route chosen when it was paired. Falling
    // through to a relay — or to a search of this network — would put its
    // traffic somewhere nobody picked, so the failure is said instead.
    final route = _record?.route;
    if (route == HostRoute.direct) {
      _noteTrouble(_directUnreachableTrouble(_record?.directEndpoint));
      return null;
    }

    final scout = route == HostRoute.relay ? null : lan;
    if (scout != null) {
      _ensureLanScout();
      var triedLan = false;
      for (final host in scout.candidates.take(3).toList()) {
        if (_abandonDial) return null;
        triedLan = true;
        final client = await _dialLan(scout, host);
        if (client != null) return client;
      }
      if (!triedLan) {
        final hinted = _lanHintHost(scout);
        if (hinted != null) {
          if (_abandonDial) return null;
          final client = await _dialLan(scout, hinted);
          if (client != null) return client;
        }
      }
    }
    for (final url in await _relayOrder()) {
      if (_abandonDial) return null;
      final client = await _dialRelay(url);
      if (client != null) return client;
    }
    return null;
  }

  /// Whether the pass in flight is still worth finishing. A Retry, an unpair
  /// or a host switch arriving mid-dial must not have to wait out every
  /// remaining candidate before the loop starts again.
  bool get _abandonDial => _closed || _record == null || _dialOvertaken;

  /// The relays to try, in order. Falls back to the phone's configured relay
  /// setting, which is also what a typed-code pairing dials.
  Future<List<Uri>> _relayOrder() async {
    final record = _record;
    if (record == null) return const [];
    // The saved candidates, plus anything the host has announced since that has
    // not been written down yet: an announcement is persisted only once a link
    // reaches `connected`, or the write would clobber the client's own record.
    final announced = _lastHostStatus?.relays ?? const <Uri>[];
    if (record.route == HostRoute.relay) {
      // The phone's configured relay is where a *desktop's* typed code meets
      // it; a box was never told about it and is not looked for there.
      return orderRelayCandidates(
        announced.isEmpty
            ? record.candidates
            : mergeRelayCandidates(record.candidates, announced),
        fallback: record.relay,
        now: _now(),
      );
    }
    return orderRelayCandidates(
      announced.isEmpty
          ? record.candidates
          : mergeRelayCandidates(record.candidates, announced),
      fallback: await pairingRelay(),
      now: _now(),
    );
  }

  /// The host's announced LAN address as something [LanPathScout] can dial.
  /// A hint, not an identity: it may name a machine DHCP has since moved, and
  /// only the sealed hello decides whether whoever answers is the host.
  DiscoveredHost? _lanHintHost(LanPathScout scout) {
    final hint = parseLanHint(_record?.lanHint);
    if (hint == null) return null;
    final address = InternetAddress.tryParse(hint.host);
    if (address == null) return null;
    final candidate = DiscoveredHost(
      address: address,
      advert: LanAdvert(port: hint.port, tag: 'hint'),
      seenAt: _now(),
    );
    return scout.inCooldown(candidate) ? null : candidate;
  }

  /// Dials the address this pairing was made at, if it has one.
  ///
  /// Not through [LanPathScout]: that speaks in `DiscoveredHost`, which needs a
  /// literal `InternetAddress`, and a box is as often a name as an IP. This
  /// hands the host string to the transport, which resolves it — so
  /// `box.example.com:47820` works exactly as `203.0.113.9:47820` does.
  ///
  /// One attempt, no generation probing: probing forward exists for a LAN host
  /// whose beacon is stale, and an address somebody typed is not a guess.
  Future<CompanionClient?> _dialDirect() async {
    final endpoint = parseLanHint(_record?.directEndpoint);
    if (endpoint == null) return null;

    final client = _newClient();
    final transport = _directDialer(endpoint.host, endpoint.port);
    _dialled = transport;
    _ownedTransport = transport;
    try {
      await client.connect(
        transport: transport,
        generation: client.pairing.generation,
        helloTimeout: kLanAttemptTimeout,
      );
      _lastPathWasLocal = true;
      _linkPath.value = CompanionLinkPath.lan;
      _noteTrouble(null);
      onLog?.call('connected straight to ${endpoint.host}:${endpoint.port}');
      return client;
    } on Object catch (error) {
      // Named. What happens next is the route's to decide — see [_dialAnyPath].
      onLog?.call(
        'direct attempt to ${endpoint.host}:${endpoint.port} failed: $error',
      );
      await _teardownClient();
      return null;
    }
  }

  /// One LAN candidate, walked across the generation window: the counters
  /// drift, and a host that has moved on hangs up on a hello naming a
  /// rendezvous it no longer holds, leaving the direct path dead behind a
  /// two-minute cooldown. Only "took the socket and then dropped it" is worth
  /// asking again at the next generation; nobody home is one dial either way.
  Future<CompanionClient?> _dialLan(
    LanPathScout scout,
    DiscoveredHost host,
  ) async {
    for (var probe = 0; probe < kCompanionProbeWindow; probe++) {
      if (_abandonDial) return null;
      final client = _newClient();
      final transport = scout.dial(host);
      _dialled = transport;
      _ownedTransport = transport;
      // Whether the far end took the socket and then dropped it — the shape
      // of `lan hello for an unknown rendezvous`, and the only shape worth a
      // second dial.
      var socketOpened = false;
      var hungUp = false;
      final watching = transport.states.listen((state) {
        if (state == TransportState.connected) socketOpened = true;
        // `disconnected` is the far end letting go. Deliberately NOT `closed`:
        // that is this method's own teardown below, and counting it would
        // probe forward against a stranger too.
        if (state == TransportState.disconnected && socketOpened) {
          hungUp = true;
        }
      });
      try {
        await client.connect(
          transport: transport,
          generation: client.pairing.generation + probe,
          helloTimeout: scout.attemptTimeout,
        );
        // The sealed hello round-tripped: this host holds the paired key. The
        // beacon's cleartext was never trusted beyond "try dialling here".
        scout.noteSuccess(host);
        _lastPathWasLocal = true;
        _linkPath.value = CompanionLinkPath.lan;
        onLog?.call('connected over the LAN');
        return client;
      } on Object catch (error) {
        // No sealed answer inside the timeout: a stranger, another pairing's
        // host, a stale advert — or a host one rendezvous ahead.
        onLog?.call('lan attempt failed: $error');
        await _teardownClient();
        if (!hungUp) break;
        if (probe + 1 < kCompanionProbeWindow) {
          onLog?.call('no host at that generation on the LAN; probing forward');
        }
      } finally {
        await watching.cancel();
      }
    }
    // Cool it down and let the relay carry on.
    scout.noteFailure(host);
    return null;
  }

  /// One relay attempt. A failure stamps the candidate so the next reconnect
  /// skips it while it cools; a success is stamped by [_connectLoop] once the
  /// client has persisted its own generation bump.
  Future<CompanionClient?> _dialRelay(Uri url) async {
    final client = _newClient(relay: url);
    try {
      await client.connect(helloTimeout: helloTimeout);
      _linkPath.value = CompanionLinkPath.relay;
      _activeRelay = url;
      _lastPathWasLocal = isLocalRelay(url);
      _noteTrouble(null);
      return client;
    } on Object catch (error) {
      // The host alone: a box relay's URL carries its access token.
      onLog?.call(scrubRelayLog('connect over ${url.host} failed: $error'));
      // Why it failed, while the transport that failed is still around to
      // say so — a relay hanging up with "no peer" is not a network fault.
      final trouble = _troubleFor(error);
      await _teardownClient();
      await _noteRelayOutcome(url, ok: false);
      // Keep the last thing actually learned rather than replacing a real
      // reason with silence: the next candidate's transport has no story yet.
      _noteTrouble(trouble ?? _trouble.value);
      return null;
    }
  }

  /// Builds the client for one attempt. [relay] points the stored record at
  /// the candidate being tried — the client dials `pairing.relay` and, on
  /// success, persists that record, so the winner becomes the saved
  /// last-known-good with no extra write of our own.
  CompanionClient _newClient({Uri? relay}) {
    final record = _record!;
    final client = CompanionClient(
      pairing: relay == null ? record : record.withRelay(relay),
      store: store,
      relayFactory: _captureFactory,
      requestTimeout: requestTimeout,
      onLog: onLog,
    );
    _client = client;
    _clientEvents = client.events.listen(_onEvent);
    return client;
  }

  RemoteTransport _captureFactory(Uri relay, RendezvousId rendezvous) {
    final transport = _relayFactory(relay, rendezvous);
    _dialled = transport;
    return transport;
  }

  /// Records how one relay behaved. Best-effort: a store that refuses the
  /// write costs the phone a little ordering, never a working link.
  Future<void> _noteRelayOutcome(Uri url, {required bool ok}) async {
    final record = _record;
    if (record == null) return;
    final at = _now();
    try {
      _all = await stored.CompanionConnections.mutate(store, (all) {
        final saved = all.byHost(record.hostId.value);
        if (saved == null) return all;
        final key = url.toString();
        final next = <RelayCandidate>[];
        var found = false;
        for (final candidate in saved.candidates) {
          if (candidate.key != key) {
            next.add(candidate);
            continue;
          }
          found = true;
          next.add(ok ? candidate.succeededAt(at) : candidate.failedAt(at));
        }
        if (!found) {
          // The configured fallback is tried without being saved; it earns a
          // place in the set only by actually working.
          if (!ok) return all;
          next.add(RelayCandidate(url: url).succeededAt(at));
        }
        all.upsert(saved.copyWith(candidates: next));
        return all;
      });
      if (_all.activeHostId?.value == record.hostId.value) {
        _record = _all.active ?? _record;
      }
    } on Object catch (error) {
      onLog?.call('relay outcome stamp failed: $error');
    }
  }
}
