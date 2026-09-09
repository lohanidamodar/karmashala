part of 'remote_companion_gateway.dart';

// The loop that keeps a link: dial, park until something says the link died,
// then wait out a backoff and dial again. The beacon's offer to upgrade a
// working relay link to the LAN is answered here too, because it is the one
// thing that ends a healthy link on purpose.

/// How long a beacon host that refused a direct dial is left alone by the LAN
/// *upgrade* — the one that spends a working link on the attempt.
///
/// Much longer than [kLanRetryCooldown] on purpose. The scout's two-minute
/// grudge is about dialling, which costs one attempt timeout and only ever
/// happens with the link already down; this one is about tearing a link that
/// works down to try again, which is what the owner reported as "connection
/// is not stable". But "never again" is not the answer either: whatever made
/// the dial fail is a thing that gets fixed, and a phone that has to be
/// force-quit to use its own LAN is not a phone that works.
const Duration kLanUpgradeRefusalTtl = Duration(minutes: 30);

extension _GatewayConnectLoop on RemoteCompanionGateway {
  void _startLoop() {
    if (_loopRunning || _closed) return;
    _ensureLanScout();
    _loopRunning = true;
    unawaited(_connectLoop());
  }

  /// Starts beacon listening once, the first time a pairing wants a link.
  void _ensureLanScout() {
    final scout = lan;
    if (scout == null || _lanStarted) return;
    _lanStarted = true;
    unawaited(scout.start());
    _lanSightings = scout.sightings.listen(_onLanSighting);
  }

  /// A beacon while the relay carries the link: re-dial, LAN first. Gateway
  /// state survives — subscriptions rebuild, held transcripts re-read.
  void _onLanSighting(DiscoveredHost host) {
    final scout = lan;
    if (scout == null || _closed || _record == null) return;
    if (_link.value != CompanionLinkState.connected) return;
    if (_linkPath.value != CompanionLinkPath.relay) return;
    // The desktop IS the relay: the embedded local relay is served on the very
    // address the beacon arrives from, so a "direct" socket would reach the
    // same machine over the same network, one hop shorter. That is not worth
    // a link — and paying for it every time the beacon repeats is what made
    // the owner's local-relay link drop on a schedule.
    if (host.address.address == _activeRelay?.host) {
      return;
    }
    if (scout.inCooldown(host)) return;
    if (_lanUpgradeIsRefused(scout.keyOf(host))) return;
    onLog?.call('beacon sighted; switching the link to the LAN');
    _declareDead();
  }

  /// Whether the beacon's offer to upgrade to [key] is still refused.
  ///
  /// The refusal expires, because the verdict behind it does not last: a
  /// firewall rule gets fixed, a desktop restarts with its LAN listener up,
  /// and the key is an `address:port` that does not even survive the
  /// desktop's next DHCP lease — so keys from every network the phone has
  /// ever been on pile up in here. One blip used to pin a phone to the relay
  /// until it was force-quit, which on Android can be days.
  bool _lanUpgradeIsRefused(String key) {
    final refusedAt = _lanUpgradeRefused[key];
    if (refusedAt == null) return false;
    if (_now().difference(refusedAt) < kLanUpgradeRefusalTtl) return true;
    _lanUpgradeRefused.remove(key);
    return false;
  }

  Future<void> _connectLoop() async {
    try {
      while (!_closed && _record != null) {
        // A pass that was overtaken is over; the next one starts clean.
        _dialOvertaken = false;
        _link.value = CompanionLinkState.connecting;
        final client = await _dialAnyPath();
        // A pass may adopt only the client it still OWNS. `_teardownClient`
        // nulls `_client` the instant a pairing, a switch or an unpair picks
        // a different desktop, and `CompanionClient.close()` cannot cancel a
        // `connect()` that is already past the host's answer — so a dial can
        // come back to a link that is nobody's any more. Adopting it would
        // throw away the death that teardown raised, put the OLD host back in
        // `_record`, bind a transport listener to nothing, declare `connected`
        // and park on a completer nothing can ever fire: the phone reads
        // "connected" with no client behind it, and every request fails.
        if (client != null && !identical(_client, client)) {
          await _closeStrayClient(client);
        } else if (client != null && !_closed && _record != null) {
          // The window opens here: from now until the completer exists, a
          // death has nowhere to land, so it is remembered instead. Anything
          // raised while merely DIALLING is news about a link that was
          // already down, and the dial that just answered is the reply to it.
          _deathPending = false;
          // The client bumped and persisted the generation counter — and, for
          // a relay path, the winning relay as the record's `relay`.
          _record = client.pairing;
          final won = _activeRelay;
          if (won != null) await _noteRelayOutcome(won, ok: true);
          _switching = false;
          // A fresh link owes nothing to what the last one failed to answer.
          _unanswered = 0;
          unawaited(_noteConnected(client.pairing));
          _resetBackoff();
          _bindTransport(_dialled);
          _link.value = CompanionLinkState.connected;
          // Now that the client has written its own record, the host's
          // greeting can safely rewrite the saved relay set.
          final greeting = _lastHostStatus;
          if (greeting != null) await _applyHostStatus(greeting);
          final died = _died = Completer<void>();
          unawaited(() async {
            try {
              await _recoverAfterConnect();
            } on Object catch (error) {
              onLog?.call('recover after connect failed: $error');
            }
          }());
          unawaited(_registerPushToken(client));
          // Anything that declared this link dead while it was still coming
          // up had nowhere to land; honour it now rather than parking on it.
          if (_deathPending) _declareDead();
          // Park here; blips are the transport's to heal. Only a request
          // nobody answered, a closed transport, unpair or close move on.
          await died.future;
          _died = null;
        }
        await _teardownClient();
        if (_closed || _record == null) break;
        if (_switching) {
          // A switch tore the old link down on purpose; the new desktop is
          // dialled at once, with no outage banner and no backoff wait.
          _switching = false;
          _link.value = CompanionLinkState.connecting;
          continue;
        }
        _link.value = CompanionLinkState.disconnected;
        final wait = (_lastPathWasLocal ? _localBackoff : _backoff).next();
        final waiter = _backoffWaiter = Completer<void>();
        unawaited(
          Future<void>.delayed(wait).then((_) {
            if (!waiter.isCompleted) waiter.complete();
          }),
        );
        await waiter.future;
        _backoffWaiter = null;
      }
    } finally {
      _loopRunning = false;
    }
  }

  /// Both schedules, because which one the next wait comes from is decided
  /// after the fact, by the path that was lost.
  void _resetBackoff() {
    _backoff.reset();
    _localBackoff.reset();
  }
}
