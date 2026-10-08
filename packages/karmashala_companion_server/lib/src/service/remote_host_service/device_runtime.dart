part of '../remote_host_service.dart';

/// Everything live for one paired device: its relay listeners — one per
/// generation in the window, per active relay — and the active sealed channel.
class _DeviceRuntime {
  _DeviceRuntime(this.service, this.device, this.key);

  final RemoteHostService service;
  PairedDevice device;
  final SecretKeyData key;

  /// generation → relay URL text → the listener waiting there. Whichever
  /// carries a frame becomes the active link.
  final Map<int, Map<String, RemoteTransport>> _listeners = {};
  final Map<int, Map<String, StreamSubscription<Uint8List>>>
  _listenerSubscriptions = {};
  final Map<int, String> _rendezvousHexByGeneration = {};

  /// Generations abandoned by [_retireGeneration], kept so a frame still in
  /// flight from one of them cannot re-open it.
  final Set<int> _retired = <int>{};

  /// Retired generations whose switched link ended while suspended — its
  /// retain window overflowed, most often. Their routes stay open for
  /// [RemoteHostService.linkResumeGrace] so a client coming back to resume
  /// is refused and redials at once, instead of hearing nothing until its
  /// own grace runs out.
  final Map<int, _Tombstone> _tombstones = {};

  /// Which relays [_listeners] are dialling; empty while parked.
  List<Uri> _listenerUrls = const [];

  /// True while EVERY relay this device could be met on is off: LAN still
  /// works, and the settings list can say so.
  bool get parked => _listenerUrls.isEmpty;

  _ActiveLink? _active;
  bool _closed = false;

  /// Whether the phone is reachable right now: set on every frame it sends,
  /// cleared when the transport carrying the active link drops.
  bool peerLive = false;

  final Stopwatch _uptime = Stopwatch()..start();

  bool get watching {
    final active = _active;
    if (!peerLive || active == null) return false;
    final said = active.watchingSaid;
    if (said == null) return true;
    return said && _uptime.elapsed < active.watchUntil;
  }

  void _onStreamAck(_ActiveLink link, int seq, bool? looking) {
    final wasWatching = watching;
    if (looking != null) {
      link.watchingSaid = looking;
      if (looking) link.watchUntil = _uptime.elapsed + service.watchLease;
    }
    final reopened = link.flow.ack(seq);
    // Either way the phone gets where things stand now, never what it missed.
    // Unawaited because this runs on the chain the sweep queues onto.
    if (reopened || (!wasWatching && watching)) {
      unawaited(sweepSessionsChanged());
    }
  }

  RemoteTransport? _watchedTransport;
  StreamSubscription<TransportState>? _liveWatch;

  /// Serialises everything for this device — frames, event pushes, seals — so
  /// `Envelope.seq` always matches the sealed sequence.
  Future<void> _chain = Future<void>.value();

  /// What this phone's `session.start` frames produced. Held here, not on the
  /// api, because the retry it exists for arrives on a fresh generation.
  final SessionStartLedger<RemoteSessionStarted> _starts =
      SessionStartLedger<RemoteSessionStarted>();
  final SessionStartLedger<RemoteSessionStarted> _resumes =
      SessionStartLedger<RemoteSessionStarted>();
  final SessionStartLedger<RemoteWorkspaceProject> _projects =
      SessionStartLedger<RemoteWorkspaceProject>();
  final SessionStartLedger<RemotePromptDelivery> _prompts =
      SessionStartLedger<RemotePromptDelivery>();

  /// Takes the device's new grant without dropping anything: the row this
  /// runtime carries, the api that judges its frames, and a `host.status` so
  /// the phone shows what it may do now. Queued like every other task, so it
  /// cannot land between a frame and its answer.
  ///
  /// A switched link took its trust at attach and a resume would keep it, so
  /// a changed grant **retires** it instead: the client reattaches afresh and
  /// reads the new grant from `host.status`.
  Future<void> applyGrant(PairedDevice updated) {
    final changed = updated.capabilities.bits != device.capabilities.bits;
    device = updated;
    final switched = _active;
    if (changed && switched != null && switched.host != null) {
      final retired = _chain.then((_) async {
        if (_closed || !identical(_active, switched)) return;
        service.onLog?.call(
          'a device\'s grant changed; its switched link is retired',
        );
        await _hostEnded(switched);
      });
      _chain = retired.then(
        (_) {},
        onError: (Object e) {
          service.onLog?.call('retiring a regranted link failed: $e');
        },
      );
      return retired;
    }
    return run((api) async {
      api.device = updated;
      await api.sendHostStatus();
    });
  }

  /// Takes a move asked in Settings: the new relay is listened on at once, and
  /// a switched link is retired, since the move is offered only at a hello —
  /// the client links again and is asked.
  Future<void> applyRelayMove(PairedDevice updated) {
    device = updated.copyWith(generation: device.generation);
    final switched = _active;
    final applied = _chain.then((_) async {
      await syncRelayListeners();
      if (_closed || switched == null || !identical(_active, switched)) return;
      if (switched.host == null || updated.relayMoveTo == null) return;
      service.onLog?.call(
        'a device was asked to move relay; its switched link is retired',
      );
      await _hostEnded(switched);
    });
    _chain = applied.then(
      (_) {},
      onError: (Object e) {
        service.onLog?.call('applying a relay move failed: $e');
      },
    );
    return applied;
  }

  bool _sweeping = false;

  /// One transcript sweep for this device, never two at once: a sweep outlasts
  /// the poll interval, and queued ticks grew the chain faster than it drained.
  Future<void> sweepTranscripts() async {
    // Reading every subscribed session's transcript is the most expensive
    // thing this host does, and a phone that is not there cannot be told what
    // it found. It asks again when it comes back — see [push].
    if (_sweeping || _closed || !peerLive) return;
    _sweeping = true;
    try {
      for (final sessionId
          in _active?.api.subscribedSessions ?? const <String>{}) {
        if (_closed || !peerLive) return;
        // The live transcript is for a phone that is looking; an approval is
        // the news a pocketed one is paired for.
        if (watching) await push((api) => api.pollTranscript(sessionId));
        await push((api) => api.recheckApproval(sessionId));
      }
      // Every card it was shown, subscribed or not: one left up after its
      // prompt went can only be refused.
      if (!_closed && peerLive) await push((api) => api.reconcileApprovals());
    } finally {
      _sweeping = false;
    }
  }

  bool _pushing = false;
  bool _pushAgain = false;

  /// Re-evaluates every subscribed session, and announces the ones this phone
  /// has never been shown, coalescing bursts: one pass after a
  /// burst says everything N passes would, and no frame waits behind a queue.
  Future<void> sweepSessionsChanged() async {
    // Nothing to say to a phone that is not listening, and saying it is what
    // the desktop was paying for on every one of its own changes — see [push].
    if (!watching) return;
    if (_pushing) {
      _pushAgain = true;
      return;
    }
    _pushing = true;
    try {
      do {
        _pushAgain = false;
        for (final sessionId
            in _active?.api.subscribedSessions ?? const <String>{}) {
          if (_closed || !watching) return;
          await push((api) => api.pushSessionChanged(sessionId));
        }
        // And any session this phone has never been shown, which no
        // subscription covers yet.
        if (!_closed && watching) await push((api) => api.pushNewSessions());
      } while (_pushAgain && !_closed && watching);
    } on Object catch (error) {
      // News nobody asked for, and every caller fires and forgets it. Asking
      // a forwarded binding fails whenever the app hangs up mid-call, and in
      // the daemon an escaped error ends the process and every PTY it holds.
      service.onLog?.call('session news failed: $error');
    } finally {
      _pushing = false;
      _pushAgain = false;
    }
  }

  /// Runs [action] only while the phone has proved it is there — for news it
  /// did not ask for. An answer to a request goes through [run] instead: the
  /// request itself is the proof.
  ///
  /// A link outlives the phone on purpose: [_active] carries the sealed
  /// channel and its sequences across a reconnect, so it is not torn down when
  /// the socket under it drops. Pushing through it anyway is what cost: every
  /// desktop change — the attention sweep runs about every 1.2 s — rebuilt the
  /// session list, sealed a frame and wrote it to a rendezvous with one socket
  /// at it. The relay buffers eight such frames and then hangs up
  /// (`kCloseImpatient`), the listener redials, and the next change does it
  /// again: a reconnect per change, for as long as the app runs, for a phone
  /// that is not there. [peerLive] is the same reading the push fan-out
  /// already uses to decide between a live frame and a sealed push.
  Future<void> push(Future<void> Function(HostSessionApi api) action) {
    if (!peerLive) return Future<void>.value();
    return run(action);
  }

  /// Runs [action] against the active api on the device's serial chain.
  Future<void> run(Future<void> Function(HostSessionApi api) action) {
    final result = _chain.then((_) async {
      final api = _active?.api;
      if (api == null || _closed) return;
      await action(api);
    });
    _chain = result.then(
      (_) {},
      onError: (Object e) {
        service.onLog?.call('device task failed: $e');
      },
    );
    return result;
  }

  void enqueueFrame(
    int generation,
    RemoteTransport transport,
    Uint8List frame,
  ) {
    _chain = _chain
        .then((_) => _onFrame(generation, transport, frame))
        .then(
          (_) {},
          onError: (Object e) {
            service.onLog?.call('frame handling failed: $e');
          },
        );
  }

  /// Establishes the window `[from, from + window)` and closes anything below.
  /// LAN routes cover it all; relay listeners open only while a relay is up.
  Future<void> listenFrom(int from) async {
    if (_closed) return;
    _retired.removeWhere((g) => g < from - kHostRelayListenWindow);
    for (var g = from; g < from + kHostRelayListenWindow; g++) {
      if (_rendezvousHexByGeneration.containsKey(g)) continue;
      final rendezvous = await rendezvousFor(key, g);
      _rendezvousHexByGeneration[g] = rendezvous.value;
      service._lanRoutes[rendezvous.value] = (
        deviceId: device.id,
        generation: g,
      );
    }
    for (final g in _rendezvousHexByGeneration.keys.toList()) {
      if (g >= from || _tombstones.containsKey(g)) continue;
      _closeGeneration(g);
    }
    await syncRelayListeners();
  }

  /// Brings the relay listeners in line with the relays that are up. The active
  /// channel and the LAN routes survive, so a returning relay costs nothing.
  Future<void> syncRelayListeners() async {
    if (_closed) return;
    final urls = service.activeRelayUrlsFor(device);
    final want = {for (final url in urls) url.toString(): url};
    for (final g in _listeners.keys.toList()) {
      for (final key in _listeners[g]!.keys.toList()) {
        if (want.containsKey(key)) continue;
        _closeRelayListener(g, key);
      }
    }
    _listenerUrls = urls;
    for (final entry in _rendezvousHexByGeneration.entries.toList()) {
      final g = entry.key;
      final open = _listeners.putIfAbsent(g, () => {});
      for (final url in want.entries) {
        if (open.containsKey(url.key)) continue;
        final transport = service._relayFactory(
          url.value,
          RendezvousId.parse(entry.value),
        );
        open[url.key] = transport;
        _listenerSubscriptions.putIfAbsent(g, () => {})[url.key] = transport
            .frames
            .listen((frame) => enqueueFrame(g, transport, frame));
      }
    }
  }

  /// Stops routing to one relay listener and closes it **without waiting for
  /// the network**.
  ///
  /// Closing a [RelayTransport] is a WebSocket goodbye handshake with the
  /// relay, and it was awaited on the path that serves a phone's *hello*:
  /// [listenFrom] retires every generation below the arriving one, and a phone
  /// probes forward, so this ran on essentially every hello. The phone's whole
  /// budget for a hello is eight seconds.
  ///
  /// So a relay that was slow to say goodbye — which is the usual reason the
  /// phone is re-dialling at all — spent that budget on a socket nobody would
  /// use again. The phone timed out, dropped, and dialled once more, and the
  /// desktop's log showed the cycle at exactly the timeout: "paired", then
  /// "a socket is waiting" 8.0 s later, repeating for a hundred seconds until
  /// the phone gave up on the relay and took the LAN link instead.
  ///
  /// The bookkeeping stays synchronous, so nothing routes to a listener this
  /// has removed. Only the goodbye is detached.
  void _closeRelayListener(int generation, String url) {
    unawaited(_listenerSubscriptions[generation]?.remove(url)?.cancel());
    final transport = _listeners[generation]?.remove(url);
    if (transport == null) return;
    unawaited(() async {
      try {
        await transport.close();
      } on Object catch (error) {
        // A listener we have already stopped reading. Saying goodbye badly is
        // not a reason to fail whatever asked for the retirement.
        service.onLog?.call('closing a retired relay listener failed: $error');
      }
    }());
  }

  /// Abandons [generation] when a frame the phone genuinely sealed cannot be
  /// admitted; its probe-forward window finds the successor unaided.
  Future<void> _retireGeneration(int generation) async {
    if (_closed) return;
    // Something already moved the link on; this frame is simply late.
    final retiring = _active;
    if (retiring?.generation != generation) return;
    _retired.add(generation);
    retiring?.liveness?.stop();
    _active = null;
    // A switched link cannot outlive its generation, suspended or not: its
    // client in the host server is released now, not at the next socket.
    retiring?.resumeGrace?.cancel();
    retiring?.host?.close('its generation was retired');
    peerLive = false;
    await _liveWatch?.cancel();
    _liveWatch = null;
    _watchedTransport = null;
    final next = generation + 1;
    device = device.copyWith(generation: next);
    service.devices.updateGeneration(device.id, next);
    // Closes everything below `next`, including the socket the confused phone
    // is sitting on — that drop is how it learns to dial again.
    await listenFrom(next);
    service.onDevicesChanged?.call();
  }

  void _closeGeneration(int generation) {
    final hex = _rendezvousHexByGeneration.remove(generation);
    if (hex != null) service._lanRoutes.remove(hex);
    for (final url
        in _listeners[generation]?.keys.toList() ?? const <String>[]) {
      _closeRelayListener(generation, url);
    }
    _listeners.remove(generation);
    _listenerSubscriptions.remove(generation);
  }

  Future<void> _onFrame(
    int generation,
    RemoteTransport transport,
    Uint8List frame,
  ) async {
    if (_closed) return;
    final tombstone = _tombstones[generation];
    if (tombstone != null) {
      await _onTombstoneFrame(generation, tombstone, transport, frame);
      return;
    }
    // A retired generation is over: anything still draining out of it must not
    // walk the window back down — `_activate` would happily re-open it.
    if (_retired.contains(generation)) {
      if (LinkHello.tryDecode(frame) != null) {
        service.onLog?.call(
          'a hello for retired generation $generation; ignored',
        );
      }
      return;
    }
    // Revocation is enforced at the door: a revoked row has no key.
    final current = service.devices.getById(device.id);
    if (current == null || current.revoked) return;

    final hello = LinkHello.tryDecode(frame);
    if (hello != null) {
      final current = _active;
      if (current != null &&
          current.generation == generation &&
          current.host != null) {
        // A client coming back for its link: the next sealed frame on this
        // socket must be its `link.resume`. A live link is suspended first —
        // the client has left the socket it was on, even if this end has not
        // heard it close.
        if (hello.resume &&
            _suspend(current, 'the client came back on a new socket')) {
          current.resumingOn = transport;
          service.onLog?.call('a desktop client is resuming its link');
          return;
        }
        // A plain hello — an older client, or one starting over — inside a
        // generation its byte stream already used: that stream cannot go on,
        // so the generation goes and the client probes forward to a fresh one.
        service.onLog?.call(
          'a desktop client said hello again on generation $generation; '
          'ending its link',
        );
        current.host!.close('the client connected again');
        return;
      }
      await _activate(generation, transport, announce: true, hello: hello);
      peerLive = true;
      return;
    }
    final moved = _active;
    if (moved != null &&
        moved.generation == generation &&
        _isStrayHostFrame(moved, transport)) {
      await _onStrayHostFrame(moved, frame);
      return;
    }
    final suspended = _active;
    if (suspended != null &&
        suspended.generation == generation &&
        (suspended.host?.suspended ?? false)) {
      await _onSuspendedFrame(suspended, transport, frame);
      return;
    }
    final active = _active?.generation == generation
        ? _reattach(transport)
        : await _activate(generation, transport, announce: false);
    final SealedFrame opened;
    try {
      opened = await active.channel.unseal(frame);
    } on SealedFrameException catch (error) {
      // The tag did not verify: letting junk move a generation would let anyone
      // who can reach the rendezvous rotate a link at will.
      service.onLog?.call('refused a frame: $error');
      return;
    } on ReplayedFrameException catch (error) {
      // A switched link that moved sockets (Stage 0 step 18) sees the frames
      // in flight on the old one twice: the copy is dropped, never a reason
      // to retire. Anyone else's repeat is refused as before.
      if (active.host != null) return;
      service.onLog?.call('retiring generation $generation: $error');
      await _retireGeneration(generation);
      return;
    } on SealedChannelException catch (error) {
      // The tag verified but the sequence repeats: the channel cannot be reset
      // — its replay window is the only guard — so the generation is retired.
      service.onLog?.call('retiring generation $generation: $error');
      await _retireGeneration(generation);
      return;
    }
    active.liveness?.heard();
    await _noteHeardOn(transport);
    final host = active.host;
    if (host != null) {
      peerLive = true;
      host.receive(opened);
      return;
    }
    final Envelope envelope;
    try {
      envelope = Envelope.fromBytes(opened.plaintext, accept: VersionRange.any);
    } on ProtocolException catch (error) {
      service.onLog?.call('refused an envelope: $error');
      return;
    }
    peerLive = true;
    service.devices.updateLastSeen(device.id, service._now().toUtc());
    if (envelope.type == FrameType.hostAttach.wire) {
      await _attachHost(active, envelope, opened.sequence);
      return;
    }
    if (envelope.type == FrameType.linkRelayMoved.wire) {
      await _onRelayMoved(active, transport, envelope);
      return;
    }
    if (envelope.type == FrameType.linkPing.wire) _armLiveness(active);
    await active.api.handleEnvelope(envelope);
  }

  /// The relay a hello should be asked to move to, or null. Only a hello that
  /// knows the frame is asked. Besides a pending move, a phone that comes back
  /// on the old relay mid-move is asked again for the relay the row is on.
  Uri? _relayMoveFor(RemoteTransport transport, LinkHello hello) {
    if (!hello.features.contains(kLinkFeatureRelayMove)) return null;
    final target = service.relayMoveTargetFor(device);
    if (target != null) return target;
    final home = device.hostedRelayUri;
    final on = _listenerUrlOf(transport);
    if (device.relayMoveSettled || home == null || on == null) return null;
    return sameRelay(on, home) ? null : home;
  }

  /// The phone saved the move it was offered on this link: the row switches,
  /// keeping the old relay listened on until the phone is heard on the new.
  Future<void> _onRelayMoved(
    _ActiveLink active,
    RemoteTransport transport,
    Envelope envelope,
  ) async {
    final offered = active.offeredMove;
    final to = envelope.payload['to'];
    if (offered == null || to is! String || to != offered.toString()) {
      service.onLog?.call('ignored a relay move nobody offered on this link');
      return;
    }
    active.offeredMove = null;
    service.devices.moveRelay(device.id, to);
    _reloadDevice();
    service.onLog?.call('a device moved to the relay at ${offered.host}');
    service.onDevicesChanged?.call();
    await _noteHeardOn(transport);
    await syncRelayListeners();
  }

  /// Settles an unsettled move once a sealed frame arrives through the relay
  /// the row is on, and lets the old relay go.
  Future<void> _noteHeardOn(RemoteTransport transport) async {
    if (device.relayMoveSettled) return;
    final home = device.hostedRelayUri;
    final on = _listenerUrlOf(transport);
    if (home == null || on == null || !sameRelay(on, home)) return;
    service.devices.settleRelayMove(device.id);
    _reloadDevice();
    service.onLog?.call('a device was heard on the relay it moved to');
    service.onDevicesChanged?.call();
    await syncRelayListeners();
  }

  void _reloadDevice() {
    final row = service.devices.getById(device.id);
    if (row != null) device = row.copyWith(generation: device.generation);
  }

  /// The relay [transport] is this device's listener on, or null for a LAN
  /// link.
  Uri? _listenerUrlOf(RemoteTransport transport) {
    for (final byUrl in _listeners.values) {
      for (final entry in byUrl.entries) {
        if (identical(entry.value, transport)) return Uri.tryParse(entry.key);
      }
    }
    return null;
  }

  /// Armed by the phone's first `link.ping`, so only a phone that pings is
  /// held to the deadline — never an older one, nor a desktop client.
  void _armLiveness(_ActiveLink active) {
    (active.liveness ??= LinkLiveness(
      deadAfter: service.linkDeadAfter,
      onDead: (silence) => _linkSilent(active, silence),
    )).start();
  }

  /// The drop a dead socket would have caused, caused on purpose: the relay
  /// listener redials its rendezvous, an accepted LAN link closes.
  void _linkSilent(_ActiveLink active, Duration silence) {
    // Already down by the ordinary route: nothing to add.
    if (_closed || !identical(_active, active) || !peerLive) return;
    service.onLog?.call(
      'a device sent nothing for ${silence.inSeconds}s; dropping its link',
    );
    peerLive = false;
    final transport = active.transport;
    if (transport is ReconnectingTransport) {
      // Not awaited, for the reason [_closeRelayListener] gives.
      unawaited(
        transport.abort().catchError((Object error) {
          service.onLog?.call('dropping a silent link failed: $error');
        }),
      );
    }
  }

  /// Switches [active] to the host protocol for a desktop client (slice 5e):
  /// answered once in the envelope, then every frame is host bytes. A pairing
  /// with no attach tier (desktop or phone client) is refused in words.
  Future<void> _attachHost(
    _ActiveLink active,
    Envelope envelope,
    int sequence,
  ) async {
    final serve = service.onHostLink;
    String? refusal;
    var code = ErrorCode.notPermitted;
    if (device.capabilities.attachTier == null) {
      refusal =
          'this pairing is neither a desktop client\'s nor the app\'s on a '
          'phone: pair again, or grant this device the app';
    } else if (serve == null) {
      refusal = 'this server takes no desktop clients';
      code = ErrorCode.internal;
    }
    if (refusal != null) {
      await _sealAndSend(active, FrameType.error, envelope.id, {
        'code': code.wire,
        'message': refusal,
      });
      return;
    }
    await _sealAndSend(active, FrameType.result, envelope.id, const {
      'attached': true,
    });
    final link = SealedHostLink(
      channel: active.channel,
      sendSealed: (sealed) {
        try {
          active.transport.send(sealed);
        } on TransportException catch (error) {
          // The frame is in the retain window: the drop that closed this
          // transport suspends the link, and a resume sends it again.
          service.onLog?.call(
            'a desktop link frame found its transport closed: '
            '${error.message}',
          );
        }
      },
      nextReceiveSequence: sequence + 1,
      deviceId: device.id,
      deviceName: device.name,
      capabilities: device.capabilities,
      retainForResume: true,
      // `link.keepalive` (Stage 0 step 18): an empty frame is answered.
      answersPings: true,
    );
    active.host = link;
    // Host-protocol bytes cannot carry a `link.ping`.
    active.liveness?.stop();
    active.liveness = null;
    unawaited(
      link.done.then((_) {
        _chain = _chain.then((_) => _hostEnded(active));
      }),
    );
    serve!(link);
  }

  /// A desktop client's byte stream is over: its generation cannot carry
  /// another, so it is retired and the socket under it closed — the client
  /// dials the next one.
  Future<void> _hostEnded(_ActiveLink active) async {
    active.resumeGrace?.cancel();
    if (_closed || !identical(_active, active)) return;
    final host = active.host;
    final reason = host?.closeReason ?? 'its byte stream ended';
    final heldOpen = host != null && host.suspended;
    service.onLog?.call(
      'a desktop client\'s link on generation ${active.generation} ended'
      '${heldOpen ? ' while suspended' : ''}: $reason',
    );
    if (heldOpen) _bury(active, reason);
    final transport = active.transport;
    await _retireGeneration(active.generation);
    try {
      await transport.close();
    } on Object {
      // Already gone.
    }
  }

  /// Keeps [active]'s generation answering resumes with a refusal for the
  /// grace: the client is away and cannot know its link is gone.
  void _bury(_ActiveLink active, String reason) {
    final generation = active.generation;
    _tombstones.remove(generation)?.expiry.cancel();
    _tombstones[generation] = _Tombstone(
      channel: active.channel,
      reason: reason,
      expiry: Timer(service.linkResumeGrace, () {
        _chain = _chain.then((_) {
          if (_tombstones.remove(generation) == null || _closed) return;
          if (generation < device.generation) _closeGeneration(generation);
        });
      }),
    );
  }

  /// A frame for a generation whose suspended link already ended: a resume
  /// hello marks its socket, and the `link.resume` that follows is answered
  /// with a refusal the client takes as "redial now". Nothing else is taken.
  Future<void> _onTombstoneFrame(
    int generation,
    _Tombstone tombstone,
    RemoteTransport transport,
    Uint8List frame,
  ) async {
    final hello = LinkHello.tryDecode(frame);
    if (hello != null) {
      if (hello.resume) {
        tombstone.resumingOn = transport;
        return;
      }
      // A fresh hello on a generation that is over: dropping the socket is
      // how the client learns to probe forward. A relay listener is the
      // rendezvous itself, and stays.
      service.onLog?.call(
        'a hello for ended generation $generation; the client probes forward',
      );
      if (!_isRelayListener(transport)) {
        unawaited(transport.close().catchError((Object _) {}));
      }
      return;
    }
    if (!identical(tombstone.resumingOn, transport)) return;
    tombstone.resumingOn = null;
    final SealedFrame opened;
    try {
      opened = await tombstone.channel.unseal(frame);
    } on Object {
      return;
    }
    Envelope? envelope;
    try {
      envelope = Envelope.fromBytes(opened.plaintext, accept: VersionRange.any);
    } on Object {
      envelope = null;
    }
    if (envelope == null || envelope.type != FrameType.linkResume.wire) return;
    service.onLog?.call(
      'refused a link.resume on generation $generation: its link ended while '
      'suspended (${tombstone.reason}); the client redials',
    );
    // An `error` answer is the refusal every client with `link.resume`
    // already takes as "redial": no new frame or code an older one misreads.
    // No await between reading the sequence and sealing: the two must agree.
    final refusal = Envelope.of(
      FrameType.error,
      seq: tombstone.channel.nextSendSequence,
      id: envelope.id,
      payload: {
        'code': ErrorCode.notFound.wire,
        'message': kLinkEndedWhileSuspended,
      },
    );
    final sealed = await tombstone.channel.seal(refusal.toBytes());
    try {
      transport.send(sealed);
    } on TransportException {
      // Gone already: the client's own deadline covers it.
    }
  }

  /// Holds [active]'s switched link for a `link.resume` instead of ending it
  /// (Stage 0 step 16): its host-server client — id, write tokens, uploads —
  /// is untouched, and what it sends waits in the link's retain window. False
  /// when it cannot be held, and the caller ends it as before.
  bool _suspend(_ActiveLink active, String why) {
    final host = active.host;
    if (host == null || host.isClosed) return false;
    if (host.suspended) return true;
    if (!host.retainForResume) return false;
    if (service._suspendedHostLinks >= kMaxSuspendedHostLinks) {
      service.onLog?.call(
        'a desktop client\'s link dropped ($why) with '
        '$kMaxSuspendedHostLinks links already suspended; ending it',
      );
      return false;
    }
    host.suspend();
    peerLive = false;
    // Frames the transport queued while down are kept in the window too; a
    // stale flush ahead of the resume answer would read as a gap.
    final transport = active.transport;
    if (transport is ReconnectingTransport) transport.discardQueued();
    active.resumeGrace?.cancel();
    active.resumeGrace = Timer(service.linkResumeGrace, () {
      _chain = _chain.then((_) => _resumeGraceOver(active));
    });
    service.onLog?.call(
      'a desktop client\'s link is suspended ($why); kept '
      '${service.linkResumeGrace.inSeconds}s for a resume '
      '(${host.retainedFrames} frames, ${host.retainedBytes} bytes kept)',
    );
    return true;
  }

  /// The grace ran out with nobody back: today's teardown.
  void _resumeGraceOver(_ActiveLink active) {
    if (_closed || !identical(_active, active)) return;
    final host = active.host;
    if (host == null || !host.suspended) return;
    service.onLog?.call(
      'a suspended desktop link was retired after '
      '${service.linkResumeGrace.inSeconds}s without a resume',
    );
    // Its `done` runs [_hostEnded]: the generation retires, the socket closes.
    host.close('not resumed within the grace');
  }

  /// Whether a frame on [transport] is one a switched link's client left
  /// behind on the socket it moved off (Stage 0 step 18, `link.promote`):
  /// the relay a desktop promoted to the LAN from, still draining what it
  /// sent before its `link.resume`. A live link takes frames only on its own
  /// socket, and a suspended one waiting for a resume only its `link.resume`
  /// on the socket that asked — anything else on the generation is a stray.
  /// A suspended link that nobody is resuming yet is not asked here: its
  /// rules are [_onSuspendedFrame]'s.
  bool _isStrayHostFrame(_ActiveLink active, RemoteTransport transport) {
    final host = active.host;
    if (host == null || host.isClosed) return false;
    final resumingOn = active.resumingOn;
    if (identical(transport, resumingOn)) return false;
    return host.suspended
        ? resumingOn != null
        : !identical(transport, active.transport);
  }

  /// A stray: taken when it is the next frame in order, dropped when it is a
  /// copy of one already taken over the new socket. It never moves the link
  /// back to the socket it came on, and never ends it.
  Future<void> _onStrayHostFrame(_ActiveLink active, Uint8List frame) async {
    final SealedFrame opened;
    try {
      opened = await active.channel.unseal(frame);
    } on SealedChannelException {
      // Junk, or a copy the new socket already brought: either way, nothing.
      return;
    }
    final host = active.host;
    if (host == null || !identical(_active, active)) return;
    // In order, a copy (dropped by the link), or a gap that ends it as any
    // gap does.
    host.receive(opened);
  }

  /// A frame for [active]'s generation while its switched link is suspended.
  /// Only a `link.resume`, as the first sealed frame on a socket that said
  /// hello with `resume`, takes it back; any other frame that opens ends it.
  Future<void> _onSuspendedFrame(
    _ActiveLink active,
    RemoteTransport transport,
    Uint8List frame,
  ) async {
    final host = active.host!;
    final resuming = identical(active.resumingOn, transport);
    active.resumingOn = null;
    final SealedFrame opened;
    try {
      opened = await active.channel.unseal(frame);
    } on SealedFrameException catch (error) {
      // Junk proves nothing and ends nothing: keep waiting for the real one.
      service.onLog?.call('refused a frame: $error');
      if (resuming) active.resumingOn = transport;
      return;
    } on SealedChannelException catch (error) {
      // A replayed resume, or anything else the window rejects: as for any
      // sealed frame, the generation cannot be trusted to go on.
      service.onLog?.call('retiring generation ${active.generation}: $error');
      await _retireGeneration(active.generation);
      return;
    }
    Envelope? envelope;
    try {
      envelope = Envelope.fromBytes(opened.plaintext, accept: VersionRange.any);
    } on Object {
      envelope = null;
    }
    if (!resuming ||
        envelope == null ||
        envelope.type != FrameType.linkResume.wire) {
      service.onLog?.call(
        'a suspended desktop link heard something other than a resume; '
        'ending it',
      );
      _adopt(active, transport);
      host.close('a suspended link heard something other than a resume');
      return;
    }
    final id = envelope.id;
    final last = envelope.payload['lastReceived'];
    final skipped = envelope.payload['skip'];
    final peerSkip = <int>[
      if (skipped is List)
        for (final s in skipped.take(kHostLinkMaxResumeFrames))
          if (s is int) s,
    ];
    var refusal = last is! int
        ? 'the resume names no lastReceived'
        : host.resumeRefusal(
            peerLastReceived: last,
            peerResumeSequence: opened.sequence,
          );
    if (refusal == null) {
      final previous = active.transport;
      _adopt(active, transport);
      final resumed = await host.resume(
        peerLastReceived: last as int,
        peerResumeSequence: opened.sequence,
        peerSkip: peerSkip,
        answer: (sequence, lastReceived, skip) => Envelope.of(
          FrameType.result,
          seq: sequence,
          id: id,
          payload: {
            'resumed': true,
            'lastReceived': lastReceived,
            'skip': skip,
          },
        ).toBytes(),
      );
      if (resumed && identical(_active, active)) {
        active.resumeGrace?.cancel();
        active.resumeGrace = null;
        peerLive = true;
        service.devices.updateLastSeen(device.id, service._now().toUtc());
        service.onLog?.call(
          'a desktop client resumed its link on generation '
          '${active.generation} (${host.retainedFrames} frames sent again)',
        );
        // An accepted LAN socket the client left; a relay listener stays,
        // since it is the rendezvous itself.
        if (!identical(previous, transport) && !_isRelayListener(previous)) {
          unawaited(previous.close().catchError((Object _) {}));
        }
        return;
      }
      refusal = host.closeReason ?? 'the link ended during the resume';
    }
    service.onLog?.call('refused a link.resume: $refusal');
    await _refuseResume(active, transport, id, refusal);
  }

  /// Answers a `link.resume` that cannot be taken, then ends the link as the
  /// grace would: the client falls back to a fresh one.
  Future<void> _refuseResume(
    _ActiveLink active,
    RemoteTransport transport,
    String? id,
    String reason,
  ) async {
    _adopt(active, transport);
    // No await between reading the sequence and sealing: the two must agree.
    final envelope = Envelope.of(
      FrameType.error,
      seq: active.channel.nextSendSequence,
      id: id,
      payload: {'code': ErrorCode.notFound.wire, 'message': reason},
    );
    final sealed = await active.channel.seal(envelope.toBytes());
    try {
      transport.send(sealed);
    } on TransportException {
      // The close says it just as well.
    }
    active.host?.close('a resume was refused: $reason');
  }

  /// Puts [active] on [transport] and watches that one for the next drop.
  void _adopt(_ActiveLink active, RemoteTransport transport) {
    active.transport = transport;
    _watchLiveness(transport);
  }

  bool _isRelayListener(RemoteTransport transport) => _listeners.values.any(
    (byUrl) => byUrl.values.any((listener) => identical(listener, transport)),
  );

  /// Tracks whether the transport carrying the active link is up. Only a
  /// frame proves the *phone* is there; a drop proves it may not be.
  void _watchLiveness(RemoteTransport transport) {
    if (identical(_watchedTransport, transport)) return;
    _liveWatch?.cancel();
    _watchedTransport = transport;
    _liveWatch = transport.states.listen((state) {
      if (state == TransportState.connected) return;
      peerLive = false;
      final active = _active;
      if (active != null && identical(active.transport, transport)) {
        final host = active.host;
        // A switched link is held for a `link.resume` (step 16). One that
        // cannot be held ends: a byte stream cannot go on over another socket
        // without one, since frames queued while this one was down would
        // arrive with a gap.
        if (host != null && !_suspend(active, 'the connection dropped')) {
          host.close('the connection dropped');
        }
      }
    });
  }

  _ActiveLink _reattach(RemoteTransport transport) {
    final active = _active!;
    // The phone redialled inside a generation: same channel, same sequences,
    // new socket.
    active.transport = transport;
    _watchLiveness(transport);
    return active;
  }

  Future<_ActiveLink> _activate(
    int generation,
    RemoteTransport transport, {
    required bool announce,
    LinkHello? hello,
  }) async {
    var active = _active;
    if (active == null || active.generation != generation) {
      final channel = await SealedChannel.forDevice(
        deviceKey: key,
        role: ChannelRole.host,
        generation: generation,
      );
      late final _ActiveLink created;
      final api = HostSessionApi(
        device: device,
        bindings: service.bindings,
        onLog: service.onLog,
        startLedger: _starts,
        resumeLedger: _resumes,
        projectLedger: _projects,
        promptLedger: _prompts,
        // Read at announcement time, never captured: a relay toggled while this
        // link is up must be in the very next `host.status`.
        relays: () => service.announcedRelaysFor(device),
        lanHint: () => service.lanHint,
        onStreamAck: (seq, looking) => _onStreamAck(created, seq, looking),
        send: (type, {id, payload = const {}}) =>
            _sealAndSend(created, type, id, payload),
      );
      created = _ActiveLink(
        generation,
        channel,
        api,
        transport,
        service.newStreamFlow(),
      );
      active?.liveness?.stop();
      // A client on a new generation has given up the old one's switched
      // link — an older client after a drop, or a newer one starting over —
      // so a suspended one is retired now, not at the end of its grace.
      active?.resumeGrace?.cancel();
      active?.host?.close('the client connected on a new generation');
      _active = created;
      active = created;
      _watchLiveness(transport);
      if (generation != device.generation) {
        device = device.copyWith(generation: generation);
        service.devices.updateGeneration(device.id, generation);
      }
      await listenFrom(generation);
      service.devices.updateLastSeen(device.id, service._now().toUtc());
      service.onDevicesChanged?.call();
    } else {
      active.transport = transport;
      _watchLiveness(transport);
    }
    if (announce) {
      // Ahead of the status: the phone attaches once greeted, and its ack must
      // be sealed before its `host.attach`.
      final move = hello == null ? null : _relayMoveFor(transport, hello);
      active.offeredMove = move;
      if (move != null) {
        await _sealAndSend(active, FrameType.linkRelayMove, 'relay-move', {
          'to': move.toString(),
        });
      }
      await active.api.sendHostStatus();
    }
    return active;
  }

  /// Seals [payload] and puts it on the wire. Answers whether a transport took
  /// it — see [RemoteSend].
  Future<bool> _sealAndSend(
    _ActiveLink active,
    FrameType type,
    String? id,
    Map<String, Object?> payload,
  ) async {
    if (_closed || _active != active) return false;
    // A desktop client's link carries host bytes only.
    if (active.host != null) return false;
    if (_isNews(type, id)) {
      switch (active.flow.admit()) {
        case StreamAdmission.send:
          break;
        case StreamAdmission.paused:
          // Not queued: the api records only what went out, so the next sweep
          // after the phone acks derives current state instead.
          return false;
        case StreamAdmission.failed:
          service.onLog?.call(
            'a device stopped acking its stream; holding news until it acks '
            '(${ErrorCode.streamStalled.wire})',
          );
          active.api.forgetDelivered();
          await _sealAndSend(active, FrameType.error, null, {
            'code': ErrorCode.streamStalled.wire,
            'message': 'the stream stalled; ack to resume',
          });
          return false;
      }
    }
    // No awaits between reading the sequence and sealing: the two must agree.
    final envelope = Envelope.of(
      type,
      seq: active.channel.nextSendSequence,
      id: id,
      payload: payload,
    );
    final sealed = await active.channel.seal(envelope.toBytes());
    try {
      active.transport.send(sealed);
      active.flow.sent(envelope.seq, sealed.length);
      return true;
    } on TransportException {
      // A transport refuses only once CLOSED, and an accepted LAN link never
      // redials, so the active one can be dead; the listeners here still queue.
      for (final fallback
          in _listeners[active.generation]?.values.toList() ??
              const <RemoteTransport>[]) {
        if (identical(fallback, active.transport)) continue;
        try {
          fallback.send(sealed);
          active.flow.sent(envelope.seq, sealed.length);
          // Adopt it: leaving the dead one in place pays this exception, and
          // this search, for every frame until the phone happens to send one.
          active.transport = fallback;
          _watchLiveness(fallback);
          return true;
        } on TransportException {
          continue;
        }
      }
      service.onLog?.call('no transport could carry a ${type.wire} frame');
      // `peerLive` decides whether news is pushed instead of sent on a link,
      // and a link that cannot carry a frame is not one.
      peerLive = false;
      return false;
    }
  }

  /// News the phone did not ask for, and so the only frames flow control may
  /// hold back. An answer, an error or the greeting always goes.
  static bool _isNews(FrameType type, String? id) =>
      id == null &&
      type != FrameType.hostStatus &&
      type != FrameType.pairingRevoked &&
      type != FrameType.error;

  Future<void> close() async {
    _closed = true;
    peerLive = false;
    _active?.resumeGrace?.cancel();
    _active?.host?.close('the device runtime closed');
    // Staged attachment bytes belong to this link. Nothing outside it can name
    // the upload, so a `.part` that outlives it is bytes nobody will quote.
    try {
      await service.bindings.discardAttachment(device.id);
    } on Object {
      // A temp file that will not delete is not a reason to fail a teardown.
    }
    await _liveWatch?.cancel();
    _liveWatch = null;
    _watchedTransport = null;
    for (final tombstone in _tombstones.values) {
      tombstone.expiry.cancel();
    }
    _tombstones.clear();
    for (final generation in _rendezvousHexByGeneration.keys.toList()) {
      _closeGeneration(generation);
    }
    _listenerUrls = const [];
    _active?.liveness?.stop();
    _active = null;
  }
}

/// A generation whose suspended link ended unresumed ([_DeviceRuntime._bury]).
class _Tombstone {
  _Tombstone({
    required this.channel,
    required this.reason,
    required this.expiry,
  });

  /// The ended link's channel: a resume opens under it, and its refusal is
  /// sealed with it.
  final SealedChannel channel;
  final String reason;
  final Timer expiry;

  /// The socket that said hello with `resume`, whose next frame is answered.
  RemoteTransport? resumingOn;
}

class _ActiveLink {
  _ActiveLink(
    this.generation,
    this.channel,
    this.api,
    this._transport,
    this.flow,
  );

  final int generation;
  final SealedChannel channel;
  final HostSessionApi api;
  RemoteTransport _transport;

  RemoteTransport get transport => _transport;

  /// Another socket for the same generation: what the api announced on the
  /// last one may never have arrived.
  set transport(RemoteTransport next) {
    if (identical(next, _transport)) return;
    _transport = next;
    api.linkReplaced();
  }

  /// Per generation, like the sequences it counts.
  final StreamFlow flow;

  /// Set once a desktop client switched this link to the host protocol.
  SealedHostLink? host;

  /// Runs out the suspension of [host] (`host.suspended`), when it is held.
  Timer? resumeGrace;

  /// The socket that said hello with `resume` for a suspended [host]: its
  /// next sealed frame must be the `link.resume`.
  RemoteTransport? resumingOn;

  /// The silence deadline, once the phone has pinged on this link.
  LinkLiveness? liveness;

  /// The relay this link's hello was asked to move to, until acknowledged.
  Uri? offeredMove;

  /// What the phone last said about looking, or null when it never has.
  bool? watchingSaid;

  /// When a "watching" stops counting unless renewed, on the runtime's clock.
  Duration watchUntil = Duration.zero;
}
