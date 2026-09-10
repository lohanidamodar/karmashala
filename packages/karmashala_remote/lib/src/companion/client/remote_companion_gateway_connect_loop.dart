part of 'remote_companion_gateway.dart';

// The loop that keeps a link: dial, park until something says the link died,
// then wait out a backoff and dial again. The beacon's offer to upgrade a
// working relay link to the LAN is heard here and handed to the promotion
// beside it, which no longer ends anything to take it up.

/// The most beacons a failed promotion may ask the next one to wait out. The
/// hold-off doubles and stops here, so a desktop that is audible and
/// permanently undialable settles into one dial every sixty-odd beacons rather
/// than into never again — whatever made a dial fail is a thing that gets fixed.
const int kLanPromotionHoldOffCap = 64;

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

  /// A beacon while the relay carries the link: dial the LAN *alongside* it.
  /// Nothing is torn down — the promotion adopts the second link only once it
  /// has answered, and hands the relay's own frames over with it.
  void _onLanSighting(DiscoveredHost host) {
    final scout = lan;
    if (scout == null || _closed || _record == null) return;
    if (_link.value != CompanionLinkState.connected) return;
    if (_linkPath.value != CompanionLinkPath.relay) return;
    // The desktop IS the relay: the embedded local relay is served on the very
    // address the beacon arrives from, so a "direct" socket would reach the
    // same machine one hop shorter, for a dial every two seconds.
    if (host.address.address == _activeRelay?.host) {
      return;
    }
    if (scout.inCooldown(host)) return;
    // Last of the gates, so the count is spent only on beacons that would
    // otherwise have cost a dial.
    if (_holdingOffPromotion()) return;
    unawaited(_promoteToLan(scout, host));
  }

  Future<void> _connectLoop() async {
    try {
      while (!_closed && _record != null) {
        // A pass that was overtaken is over; the next one starts clean.
        _dialOvertaken = false;
        _link.value = CompanionLinkState.connecting;
        final client = await _dialAnyPath();
        // A pass may adopt only the client it still OWNS. `_teardownClient`
        // nulls `_client` the instant another desktop is picked, and a
        // `connect()` already past the host's answer cannot be cancelled —
        // adopting that link declares `connected` with no client behind it.
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
