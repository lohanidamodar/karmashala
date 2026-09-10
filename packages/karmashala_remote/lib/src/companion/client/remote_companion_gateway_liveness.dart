part of 'remote_companion_gateway.dart';

// What makes `connected` mean the host answered: the transport's states, the
// re-proof after a socket comes back, the heal grace before the link is
// declared dead, and the teardown that follows. The trouble sentences live
// here because they are what this file learns.

/// What "nobody was at the rendezvous" reads like to someone holding a
/// phone. Never "check your connection": the network is demonstrably fine,
/// since the relay answered.
const String _kHostAbsentTrouble =
    'Your desktop is not answering on this relay — check that Karmashala '
    'is running, and that it is set to the same relay.';

/// And what "the meeting place itself would not answer" reads like. Never
/// about the desktop: nothing here has learned anything about it yet.
const String _kRelayUnreachableTrouble =
    'This phone could not reach the relay your desktop uses. On mobile data '
    'that usually means the desktop is only reachable on its own network.';

extension _GatewayLiveness on RemoteCompanionGateway {
  void _bindTransport(RemoteTransport? transport) {
    final previous = _transportStates;
    _transportStates = null;
    if (previous != null) unawaited(previous.cancel());
    if (transport == null) return;
    // The dial that got us here already proved the host answers, so the
    // FIRST connected state needs no proving. Every later one does.
    var dropped = false;
    _transportStates = transport.states.listen((state) {
      if (_client == null) return;
      switch (state) {
        case TransportState.connected:
          _cancelHeal();
          if (!dropped) {
            _link.value = CompanionLinkState.connected;
            return;
          }
          dropped = false;
          // A socket at a rendezvous is NOT a link: the relay accepts one
          // whether or not the host is still at the other end, and it will
          // hold that lonely socket for two minutes before hanging up. So
          // the far end has to say hello again before this claims connected.
          unawaited(_reproveLink());
        case TransportState.connecting:
        case TransportState.disconnected:
          dropped = true;
          // A drop while a second link is being proved to the SAME desktop is
          // usually that promotion's own doing. Held, not reported; the heal
          // below still bounds it, and a promotion that does not happen hands
          // the drop straight back.
          if (_promoting) {
            _dropDeferred = true;
            _armHeal();
            return;
          }
          // The transport re-dials the same rendezvous by itself; the
          // channel and its sequences survive the blip (loop 64's rule).
          if (_link.value == CompanionLinkState.connected) {
            _link.value = CompanionLinkState.connecting;
          }
          _armHeal();
        case TransportState.closed:
          _declareDead();
        case TransportState.idle:
          break;
      }
    });
  }

  /// Makes `connected` mean *the host answered*, after a socket came back:
  /// re-sends the hello on the existing channel, which the host reattaches
  /// without moving any sequence or key. Silence means the phone is alone at
  /// the rendezvous, so the loop re-dials instead of parking on a lie.
  Future<void> _reproveLink() async {
    final client = _client;
    if (client == null || _closed) return;
    final attempt = ++_reproveAttempt;
    try {
      await client.rehandshake(timeout: helloTimeout);
    } on Object catch (error) {
      if (_closed || _client != client || attempt != _reproveAttempt) return;
      onLog?.call('the socket came back but the host did not: $error');
      // The socket came back and the hello went unanswered: from this side
      // that IS "the desktop is not on this relay", whatever the close code
      // said, so it is stated rather than inferred.
      _noteTrouble(_troubleFor(error) ?? _kHostAbsentTrouble);
      _declareDead();
      return;
    }
    if (_closed || _client != client || attempt != _reproveAttempt) return;
    _noteTrouble(null);
    _link.value = CompanionLinkState.connected;
  }

  /// The plainest true sentence about why the link is not up, or null when
  /// there is nothing to add. Neither "no peer" nor "nobody at any rendezvous"
  /// is a network failure, and telling someone to check their wifi when their
  /// desktop is simply closed wastes their afternoon.
  String? _troubleFor([Object? error]) {
    if (error is RemoteApiException) {
      // "The relay would not take the socket" and "nobody was at the
      // rendezvous" are different facts: one is about the meeting place, the
      // other about the desktop.
      if (error.relayUnreachable) return _kRelayUnreachableTrouble;
      if (error.hostAbsent) return _kHostAbsentTrouble;
    }
    final transport = _dialled;
    if (transport is RelayTransport &&
        transport.lastCloseCode == kRelayCloseNoPeer) {
      return _kHostAbsentTrouble;
    }
    return null;
  }

  void _noteTrouble(String? trouble) {
    if (_trouble.value == trouble) return;
    // Said on its own stream, because it is learned on its own: a dial that
    // failed while the phone was already `connecting` changes no link state,
    // and re-emitting an unchanged one rebuilds nothing.
    _trouble.value = trouble;
  }

  /// A transport that dropped redials its OWN endpoint forever, and that
  /// endpoint may be one nobody is at any more. Nothing else watches it — the
  /// re-proof runs only when a socket comes BACK — so the transport gets one
  /// grace period to heal itself and is then declared dead, which is what lets
  /// the loop re-read the candidate set.
  void _armHeal() {
    final scout = lan;
    final grace = _linkPath.value == CompanionLinkPath.lan && scout != null
        ? scout.attemptTimeout * 2
        : linkHealGrace;
    _healTimer ??= Timer(grace, () {
      _healTimer = null;
      if (_closed || _link.value == CompanionLinkState.connected) return;
      onLog?.call('the link did not heal itself; dialling every path again');
      _declareDead();
    });
  }

  void _cancelHeal() {
    _healTimer?.cancel();
    _healTimer = null;
  }

  Future<void> _recoverAfterConnect() async {
    await _refreshSessions();
    // Only transcripts a re-dial left stale; one just primed on this very
    // link is already current and must not be re-emitted.
    for (final entry in _transcripts.entries.toList()) {
      final state = entry.value;
      if (!state.stale) continue;
      if (state.listeners.isEmpty) {
        // Nobody is watching: forget, and the next listen re-reads.
        state.loaded = false;
        state.stale = false;
        continue;
      }
      // Resume from the cursor rather than re-read the tail: a phone away for a
      // hundred turns is entitled to all hundred. `stale` is cleared first
      // because the appends it blocks are precisely the ones fetched here.
      state.stale = false;
      var resumed = false;
      try {
        resumed = await _drainNewer(entry.key);
      } on Object catch (error) {
        onLog?.call('transcript resume for ${entry.key} failed: $error');
      }
      if (resumed) continue;
      try {
        await _reloadTranscript(entry.key);
      } on Object catch (error) {
        onLog?.call('transcript recover for ${entry.key} failed: $error');
        state.stale = true;
      }
    }
  }

  /// Disposes of a client whose link was torn down while it was still
  /// dialling. Nothing else holds it, and a socket left open at a rendezvous
  /// keeps the relay believing this phone is still there.
  Future<void> _closeStrayClient(CompanionClient client) async {
    onLog?.call('a dial answered after its link was torn down; dropping it');
    try {
      await client.close();
    } on Object catch (error) {
      onLog?.call('stray client close failed: $error');
    }
  }

  Future<void> _teardownClient() async {
    _cancelHeal();
    final events = _clientEvents;
    _clientEvents = null;
    final states = _transportStates;
    _transportStates = null;
    final client = _client;
    _client = null;
    final owned = _ownedTransport;
    _ownedTransport = null;
    _dialled = null;
    _linkPath.value = null;
    _activeRelay = null;
    // [_lastHostStatus] deliberately survives: it is what the host said about
    // *itself*, and the announcement that matters most arrives seconds before a
    // link dies — a local relay whose address moved announces the new one and
    // then takes the old socket down with it. See [_relayOrder].
    _subscribed.clear();
    for (final state in _transcripts.values) {
      if (state.loaded) state.stale = true;
    }
    await events?.cancel();
    await states?.cancel();
    if (client != null) {
      try {
        await client.close();
      } on Object catch (error) {
        onLog?.call('client close failed: $error');
      }
    }
    if (owned != null) {
      // A supplied (LAN) transport is never the client's to close.
      try {
        await owned.close();
      } on Object catch (error) {
        onLog?.call('lan transport close failed: $error');
      }
    }
  }

  /// Tears the link down. [keepState] leaves the link state alone — a switch
  /// owns it, and must not flash "host unreachable" on its way to the desktop
  /// the user just chose.
  Future<void> _dropLink({bool keepState = false}) async {
    // Deliberate: whoever called this has already chosen a different desktop
    // (or none), so a pass still working through the old one's candidates is
    // finished with.
    _dialOvertaken = true;
    _declareDead();
    final waiter = _backoffWaiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    await _teardownClient();
    if (!keepState) _link.value = CompanionLinkState.disconnected;
  }

  void _declareDead() {
    final died = _died;
    if (died != null) {
      if (!died.isCompleted) died.complete();
      return;
    }
    // No completer to take it. Remember, so the loop honours it rather than
    // parking on a link that was already declared dead before the park.
    _deathPending = true;
  }
}
