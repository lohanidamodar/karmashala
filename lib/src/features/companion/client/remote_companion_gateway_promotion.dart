part of 'remote_companion_gateway.dart';

// Make-before-break: the relay→LAN upgrade as a second link rather than a
// hang-up.
//
// The old upgrade declared the working link dead, tore it down, dialled again
// and then went looking for whatever had gone missing in between — a new
// generation, sequences from zero, every transcript stale, a backoff step and
// a page walk, all so the phone could use a socket one hop shorter. Here the
// LAN candidate is dialled on a transport and a client OF ITS OWN while the
// relay keeps carrying, and it becomes the link only once its first sealed
// frame has round-tripped.
//
// **The new link starts its own sequence counter, at the next generation.**
// That is not a convenience, it is what the framing allows. `SealedChannel`
// binds the generation into both direction keys and admits a frame only if its
// sequence is ahead of the highest seen or inside the 64-frame replay window;
// a second channel at the SAME generation would open its send counter at zero
// against a peer whose window is already past it, and the host's own answer to
// that is `_retireGeneration` — it kills the generation, both links with it.
// Continuing one counter is only possible by carrying the same channel object
// onto the new socket, which is a re-attach (`rehandshake`) and therefore
// break-before-make by construction. So each link is monotonic in itself, the
// old one's frames can never be replayed into the new one, and what actually
// has to survive the switch is the *application* cursor — which it does.

/// A dialled LAN candidate that has proved itself and is not the link yet.
typedef _StandbyLink = ({
  CompanionClient client,
  RemoteTransport transport,
  RemoteHostStatus status,
});

extension _GatewayPromotion on RemoteCompanionGateway {
  /// The beacon's offer, answered without spending the link that works.
  Future<void> _promoteToLan(LanPathScout scout, DiscoveredHost host) async {
    if (_promoting) return;
    _promoting = true;
    try {
      final standby = await _dialStandbyLan(scout, host);
      if (standby == null) {
        _releaseDeferredDrop();
        onLog?.call(
          'lan promotion: the dial found nobody; the relay is untouched',
        );
        return;
      }
      if (!_canAdopt) {
        // The world moved while the dial was in flight: the link went, or a
        // pairing, a switch or an unpair chose a different desktop.
        await _dropDial(standby.client, standby.transport);
        _releaseDeferredDrop();
        onLog?.call('lan promotion: the link moved under the dial; dropped it');
        return;
      }
      await _adoptStandby(standby);
      scout.noteSuccess(host);
      onLog?.call('lan promotion: adopted the LAN link');
    } finally {
      _promoting = false;
    }
  }

  /// Whether a standby is still worth adopting. The relay link that was up
  /// when the beacon arrived has to still be the link this gateway is holding.
  bool get _canAdopt =>
      !_closed &&
      _record != null &&
      _client != null &&
      _link.value == CompanionLinkState.connected &&
      _linkPath.value == CompanionLinkPath.relay;

  /// Dials [host] on a transport and a client of its own.
  ///
  /// Nothing here writes `_client`, `_dialled`, `_ownedTransport` or
  /// `_linkPath`. A second dial that borrowed any of those would have taken
  /// the working link down to go looking for a better one, which is precisely
  /// what this replaces.
  ///
  /// Returns only once the host's sealed `host.status` has come back: the
  /// beacon's cleartext is an address to try and nothing more, and the round
  /// trip is the only thing that says the desktop holding the paired key is at
  /// the other end.
  Future<_StandbyLink?> _dialStandbyLan(
    LanPathScout scout,
    DiscoveredHost host,
  ) async {
    final record = _record;
    if (record == null) return null;
    // The same walk `_dialLan` takes, for the same reason: the counters drift,
    // and a host that has moved on hangs up on a hello naming a rendezvous it
    // is no longer holding.
    for (var probe = 0; probe < kCompanionProbeWindow; probe++) {
      if (_closed || _record == null) return null;
      final client = CompanionClient(
        pairing: record,
        store: store,
        relayFactory: _relayFactory,
        requestTimeout: requestTimeout,
        onLog: onLog,
      );
      final transport = scout.dial(host);
      var socketOpened = false;
      var hungUp = false;
      final watching = transport.states.listen((state) {
        if (state == TransportState.connected) socketOpened = true;
        if (state == TransportState.disconnected && socketOpened) {
          hungUp = true;
        }
      });
      try {
        final status = await client.connect(
          transport: transport,
          generation: record.generation + probe,
          helloTimeout: scout.attemptTimeout,
        );
        return (client: client, transport: transport, status: status);
      } on Object catch (error) {
        onLog?.call('lan standby attempt failed: $error');
        await _dropDial(client, transport);
        if (!hungUp) break;
      } finally {
        await watching.cancel();
      }
    }
    scout.noteFailure(host);
    _lanUpgradeRefused[scout.keyOf(host)] = _now();
    return null;
  }

  /// Makes the standby the link, in place.
  ///
  /// No `_declareDead`, no teardown, no stale mark, no backoff step and no
  /// recovery: everything this gateway holds — the transcript cursors and the
  /// listeners on them, the session list, the approvals — belongs to the
  /// *pairing*, not to the socket underneath it, and the pairing did not
  /// change.
  Future<void> _adoptStandby(_StandbyLink standby) async {
    final oldClient = _client;
    final oldEvents = _clientEvents;
    final oldOwned = _ownedTransport;

    _client = standby.client;
    _clientEvents = standby.client.events.listen(_onEvent);
    _dialled = standby.transport;
    _ownedTransport = standby.transport;
    // The client persisted the counter it used, so the record moves with it.
    _record = standby.client.pairing;
    _activeRelay = null;
    _lastPathWasLocal = true;
    _lastHostStatus = standby.status;
    // A fresh link owes nothing to what the last one failed to answer.
    _unanswered = 0;
    _dropDeferred = false;
    // The link state is deliberately untouched. It was connected a moment ago
    // and it is connected now; a phone that flashed "Connecting…" would be
    // reporting an outage that did not happen. `_linkSince` moves only when
    // the state changes, so the age on screen keeps counting from when this
    // link came up — which is the visible proof that nothing broke. Only the
    // path word changes.
    _linkPath.value = CompanionLinkPath.lan;
    // Rebinds the liveness watch, cancelling the old transport's: that socket
    // is already going, and its drop must not declare anything dead.
    _bindTransport(standby.transport);

    await oldEvents?.cancel();
    await _carryOver(standby.client);
    await oldClient?.close();
    await oldOwned?.close();
    unawaited(_applyHostStatus(standby.status));
  }

  /// Re-states on the new link what the old one was carrying.
  ///
  /// The host builds a fresh session api per generation, so on the second link
  /// nothing is subscribed and no transcript has a poll cursor — a promotion
  /// that skipped this would leave a phone reading a conversation nothing
  /// would ever append to. Both are re-sent from what this phone already
  /// holds, never from zero: no row crosses twice, and the tail is not
  /// re-read.
  Future<void> _carryOver(CompanionClient client) async {
    final sessionIds = _subscribed.toList();
    _subscribed.clear();
    for (final sessionId in sessionIds) {
      await _ensureSubscribed(client, sessionId);
    }
    for (final entry in _transcripts.entries.toList()) {
      final state = entry.value;
      // A stale one belongs to the reconnect path, which owns its recovery.
      if (!state.loaded || state.stale) continue;
      try {
        // One bounded page from the cursor this phone holds, which is also
        // what re-arms the host's poll: nothing when nothing moved, and
        // exactly the new turns when something did.
        if (!await _drainNewer(entry.key)) _startReload(entry.key);
      } on Object catch (error) {
        onLog?.call('carrying ${entry.key} to the new link failed: $error');
        _startReload(entry.key);
      }
    }
  }

  /// Lets go of a dial that will not be adopted. Both halves by hand: a client
  /// never owns a transport it was handed.
  Future<void> _dropDial(
    CompanionClient client,
    RemoteTransport transport,
  ) async {
    try {
      await client.close();
    } on Object catch (error) {
      onLog?.call('standby client close failed: $error');
    }
    try {
      await transport.close();
    } on Object catch (error) {
      onLog?.call('standby transport close failed: $error');
    }
  }

  /// Hands back a drop that was held while a promotion was in flight.
  ///
  /// The host moves to the new rendezvous the moment it reads the hello, and
  /// the relay closes the pair it was forwarding — so the link being replaced
  /// usually drops *before* this phone knows the promotion worked. Reporting
  /// that as an outage would put "Connecting…" on screen for the width of one
  /// round trip, which is the flicker this whole change deletes. When the
  /// promotion does not happen, the drop is real and is applied here.
  void _releaseDeferredDrop() {
    if (!_dropDeferred) return;
    _dropDeferred = false;
    if (_link.value == CompanionLinkState.connected) {
      _link.value = CompanionLinkState.connecting;
    }
    // The heal may have expired against a link that still read `connected`.
    _armHeal();
  }
}
