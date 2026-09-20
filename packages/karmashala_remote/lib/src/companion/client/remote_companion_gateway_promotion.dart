part of 'remote_companion_gateway.dart';

// Make-before-break: the relay→LAN upgrade as a second link rather than a
// hang-up. **The new link starts its own sequence counter, at the next
// generation** — a second channel at the SAME generation would open at zero
// against a peer whose 64-frame replay window is already past it, and the host
// answers that by retiring the generation and both links with it. What has to
// survive the switch is the *application* cursor, and it does.

/// A dialled LAN candidate that has proved itself and is not the link yet.
typedef _StandbyLink = ({
  CompanionClient client,
  RemoteTransport transport,
  RemoteHostStatus status,
});

/// The link a promotion is replacing, held intact until the new one has
/// carried a frame — and put back when it has not.
typedef _ReplacedLink = ({
  CompanionClient? client,
  StreamSubscription<CompanionEvent>? events,
  RemoteTransport? dialled,
  RemoteTransport? owned,
  Uri? relay,
  bool wasLocal,
  List<String> subscribed,
});

extension _GatewayPromotion on RemoteCompanionGateway {
  /// The beacon's offer, answered without spending the link that works.
  Future<void> _promoteToLan(LanPathScout scout, DiscoveredHost host) async {
    if (_promoting) return;
    _promoting = true;
    try {
      final standby = await _dialStandbyLan(scout, host);
      if (standby == null) {
        _promotionFailed();
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
      if (await _adoptStandby(standby)) {
        scout.noteSuccess(host);
        // The path works: the next beacon after a fall back to the relay
        // deserves an immediate try, not the count this one climbed to.
        _promotionHoldOff = 0;
        _promotionPenalty = 0;
        onLog?.call('lan promotion: adopted the LAN link');
        return;
      }
      scout.noteFailure(host);
      _promotionFailed();
      _releaseDeferredDrop();
      onLog?.call('lan promotion: the new link carried nothing; rolled back');
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

  /// Dials [host] on a transport and a client of its own — nothing here writes
  /// `_client`, `_dialled`, `_ownedTransport` or `_linkPath`. Returns only once
  /// the host's sealed `host.status` has come back: the beacon's cleartext is
  /// an address to try and nothing more.
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
        // The same words the ordinary dial path uses, because it is the same
        // event; which path spent the dial is said by the `lan promotion:` line
        // beside it, and a fixture counting LAN dials must see both.
        onLog?.call('lan attempt failed: $error');
        await _dropDial(client, transport);
        if (!hungUp) break;
      } finally {
        await watching.cancel();
      }
    }
    scout.noteFailure(host);
    return null;
  }

  /// Whether this beacon is one a failed promotion asked to wait out. A
  /// promotion costs a second transport and one hello timeout and never touches
  /// the working link, so a flapping LAN earns a widening count, not a refusal.
  bool _holdingOffPromotion() {
    if (_promotionHoldOff <= 0) return false;
    _promotionHoldOff--;
    onLog?.call('lan promotion: held off, $_promotionHoldOff beacon(s) to go');
    return true;
  }

  /// A promotion that did not land doubles what the next one waits for.
  void _promotionFailed() {
    _promotionPenalty = _promotionPenalty == 0
        ? 1
        : (_promotionPenalty * 2).clamp(1, kLanPromotionHoldOffCap);
    _promotionHoldOff = _promotionPenalty;
  }

  /// Makes the standby the link, in place: no teardown, no stale mark, no
  /// backoff step. Everything this gateway holds belongs to the *pairing*, not
  /// to the socket underneath it, and the pairing did not change.
  Future<bool> _adoptStandby(_StandbyLink standby) async {
    final replaced = (
      client: _client,
      events: _clientEvents,
      dialled: _dialled,
      owned: _ownedTransport,
      relay: _activeRelay,
      wasLocal: _lastPathWasLocal,
      subscribed: _subscribed.toList(),
    );

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
    // The link state is deliberately untouched: it was connected a moment ago
    // and is connected now, and `_linkSince` moves only when the state changes,
    // so the age on screen keeps counting. Only the path word changes.
    _linkPath.value = CompanionLinkPath.lan;
    // Rebinds the liveness watch, cancelling the old transport's: that socket
    // is already going, and its drop must not declare anything dead.
    _bindTransport(standby.transport);

    // **The relay is held until the new link has carried a frame**, and its
    // events stay subscribed through the window: `_applyAppended` drops a
    // repeat by cursor, so listening to both can gain a row and never repeat one.
    if (!await _carryOver(standby.client, replaced.subscribed)) {
      await _rollBack(replaced, standby);
      return false;
    }
    _dropDeferred = false;
    await replaced.events?.cancel();
    await replaced.client?.close();
    await replaced.owned?.close();
    unawaited(_applyHostStatus(standby.status));
    return true;
  }

  /// Gives the relay its link back when the new one would not carry. It is
  /// still open — holding it is the whole reason the old client is not closed at
  /// the swap — so the phone lands on the link it was using a moment ago.
  Future<void> _rollBack(_ReplacedLink replaced, _StandbyLink standby) async {
    final adopted = _clientEvents;
    _client = replaced.client;
    _clientEvents = replaced.events;
    _dialled = replaced.dialled;
    _ownedTransport = replaced.owned;
    _activeRelay = replaced.relay;
    _lastPathWasLocal = replaced.wasLocal;
    _linkPath.value = CompanionLinkPath.relay;
    _subscribed
      ..clear()
      ..addAll(replaced.subscribed);
    await adopted?.cancel();
    _bindTransport(replaced.dialled);
    await _dropDial(standby.client, standby.transport);
  }

  /// Re-states on the new link what the old one was carrying. The host builds a
  /// fresh session api per generation, so nothing is subscribed and no
  /// transcript has a cursor there. Both are re-sent from what this phone holds,
  /// never from zero: no row crosses twice, and the tail is not re-read.
  Future<bool> _carryOver(
    CompanionClient client,
    List<String> sessionIds,
  ) async {
    _subscribed.clear();
    // The proof frame: a LAN path can be half open — the socket reads
    // `connected`, the hello round-tripped, and nothing sent after it leaves
    // the phone — and that is the link the relay must not be closed for.
    try {
      if (sessionIds.isEmpty) {
        // Nothing was subscribed, so the list is what there is to ask for.
        await client.listSessionRows();
      } else {
        await client.subscribeSession(sessionIds.first);
        _subscribed.add(sessionIds.first);
      }
    } on RemoteApiException catch (error) {
      // A refusal is an ANSWER: the host read the frame and said no, which is
      // the strongest evidence this path carries. Only silence is not.
      if (error.code == null) {
        onLog?.call('the new link would not carry a frame: ${error.message}');
        return false;
      }
    } on Object catch (error) {
      onLog?.call('the new link would not carry a frame: $error');
      return false;
    }
    for (final sessionId in sessionIds.skip(1)) {
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
    return true;
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

  /// Hands back a drop that was held while a promotion was in flight. The host
  /// moves to the new rendezvous the moment it reads the hello, so the link
  /// being replaced usually drops *before* this phone knows the promotion
  /// worked; when it does not happen, the drop is real and is applied here.
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
