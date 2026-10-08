part of '../desktop_client.dart';

const String _attachId = 'attach';

/// Owns a desktop link's socket — first the one it was opened on, then any
/// it was resumed over — the heal loop between them, the promotion off a
/// relay (Stage 0 step 18) and the idle link's keepalive.
class _DesktopLinkKeeper {
  _DesktopLinkKeeper({
    required this.channel,
    required this.rendezvous,
    required this.generation,
    required this.resume,
    required this.onEnvelope,
    this.relayHost,
    this.relay,
    this.onRoute,
  });

  final SealedChannel channel;
  final RendezvousId rendezvous;
  final int generation;
  final DesktopLinkResume? resume;

  /// The relay the link is on now, or null when it is not on one. Only a
  /// link on a relay is promoted.
  String? relayHost;

  /// The relay itself, beside [relayHost]: two relays on one host are two
  /// routes. Null off every relay, or where the dial did not say.
  Uri? relay;

  /// Hears [relay] each time a resume or a promotion lands the link.
  final void Function(Uri? relay)? onRoute;

  /// The relay a promotion set aside: still open and still subscribed, but
  /// no longer read, until the new socket has taken the resume (then it is
  /// let go) or has not (then the link goes back onto it).
  ({
    RemoteTransport transport,
    StreamSubscription<Uint8List>? frames,
    StreamSubscription<TransportState>? states,
  })?
  _parked;
  var _promoting = false;
  StreamSubscription<void>? _chances;
  Timer? _recheck;
  Duration _holdOff = Duration.zero;
  DateTime? _promoteNotBefore;

  /// Inbound silence on the link, with `link.keepalive`.
  LinkLiveness? _liveness;

  StreamSubscription<void>? _proofs;
  Timer? _proofWindow;

  /// Ends a held link a proof found, if it has not resumed by then.
  Timer? _afterProof;

  /// Frames taken off the current socket, counted so a proof can tell
  /// whether anything arrived after its ping.
  var _heard = 0;

  /// Cuts the heal loop's wait between passes short.
  Completer<void>? _healWake;

  /// Frames before the link exists: the switch's envelopes.
  final void Function(Envelope envelope, SealedFrame opened) onEnvelope;

  SealedHostLink? link;

  /// Whether the first socket ever connected, for the dial's error text.
  bool everConnected = false;

  RemoteTransport? _transport;
  StreamSubscription<Uint8List>? _frames;
  StreamSubscription<TransportState>? _states;
  Future<void> _chain = Future<void>.value();

  /// The resume in flight on [_transport], if any.
  _ResumeAttempt? _attempt;
  Timer? _heal;
  var _attempts = 0;

  /// Whether this suspension's outcome has been logged: once each.
  var _told = true;
  var _released = false;

  /// The link's way out: whichever socket it is on now. While the link is
  /// suspended it hands nothing here; a resume sends through the new one.
  void sendSealed(Uint8List sealed) {
    final transport = _transport;
    if (transport == null) {
      throw const TransportException('the link has no connection');
    }
    transport.send(sealed);
  }

  /// Makes [transport] the link's socket, reading its frames and drops.
  void adopt(RemoteTransport transport) {
    _transport = transport;
    var connected = false;
    _frames = transport.frames.listen((frame) {
      _chain = _chain.then((_) => _onFrame(transport, frame));
    });
    _states = transport.states.listen((state) {
      if (!identical(_transport, transport)) return;
      if (state == TransportState.connected) {
        connected = true;
        everConnected = true;
        _attempt?.connected();
        return;
      }
      if (state != TransportState.disconnected &&
          state != TransportState.closed) {
        return;
      }
      final attempt = _attempt;
      if (attempt != null) {
        attempt.fail(
          connected ? 'the connection dropped' : 'nothing could be reached',
        );
        return;
      }
      if (connected) _dropped();
    });
  }

  /// Lets go of the current socket, and closes it.
  Future<void> _detach({bool discard = false}) async {
    final transport = _transport;
    final frames = _frames;
    final states = _states;
    _transport = null;
    _frames = null;
    _states = null;
    // Frames it queued while down are in the link's retain window too; a
    // stale flush must never go out anywhere (step 16's contract).
    if (discard && transport is ReconnectingTransport) {
      transport.discardQueued();
    }
    await frames?.cancel();
    await states?.cancel();
    try {
      await transport?.close();
    } on Object {
      // Already gone.
    }
  }

  /// The link is over: nothing more is dialled, and its socket closes.
  Future<void> release() async {
    if (_released) return;
    _released = true;
    _heal?.cancel();
    _recheck?.cancel();
    _liveness?.stop();
    _proofWindow?.cancel();
    _afterProof?.cancel();
    final proofs = _proofs;
    _proofs = null;
    await proofs?.cancel();
    _wakeHeal();
    final chances = _chances;
    _chances = null;
    await chances?.cancel();
    final parked = _parked;
    _parked = null;
    if (parked != null) await _letGo(parked);
    final current = link;
    if (current != null && current.suspended) {
      // Ended while held some other way: the window overflowed, too many
      // resumes, an answer that could not be taken, or its owner hung up.
      _tell(
        'link to ${resume?.hostName ?? 'the server'} could not be resumed '
        '(${current.closeReason}); redialling',
      );
    }
    _attempt?.fail('the link ended');
    await _detach();
  }

  Future<void> _onFrame(RemoteTransport transport, Uint8List frame) async {
    // A socket given up on: whatever it still carries is not read.
    if (!identical(_transport, transport)) return;
    final attempt = _attempt;
    final SealedFrame opened;
    try {
      opened = await channel.unseal(frame);
    } on SealedChannelException catch (error) {
      // Set aside while it was opening: a promotion's relay is not read.
      if (!identical(_transport, transport)) return;
      if (attempt != null) {
        attempt.fail('a frame would not open: $error');
      } else {
        link?.close('a frame would not open: $error');
      }
      return;
    }
    // Set aside while it was opening (a promotion took the link off this
    // socket): not taken, so the resume's `lastReceived` stays true and the
    // server sends it again on the new one — where it must open once more.
    if (!identical(_transport, transport)) {
      channel.forget(opened.sequence);
      return;
    }
    _liveness?.heard();
    _heard++;
    if (attempt != null) {
      await _onResumeAnswer(attempt, transport, opened);
      return;
    }
    final current = link;
    if (current != null) {
      current.receive(opened);
      return;
    }
    final Envelope envelope;
    try {
      envelope = Envelope.fromBytes(opened.plaintext, accept: VersionRange.any);
    } on ProtocolException {
      return;
    }
    onEnvelope(envelope, opened);
  }

  /// The socket under a live link dropped: hold the link for a resume when
  /// the server offers one, or end it as before.
  void _dropped() {
    final current = link;
    if (current == null || current.isClosed || current.suspended) return;
    final resume = this.resume;
    if (resume == null || !current.retainForResume) {
      current.close('the connection dropped');
      return;
    }
    bool offered;
    try {
      offered = resume.offered();
    } on Object {
      offered = false;
    }
    if (!offered) {
      resume.onLog?.call(
        'link to ${resume.hostName} dropped; the server offers no resume, '
        'redialling',
      );
      current.close('the connection dropped');
      return;
    }
    current.suspend();
    unawaited(_detach(discard: true));
    resume.onLog?.call(
      'link to ${resume.hostName} dropped; resuming it within '
      '${resume.grace.inSeconds}s',
    );
    _hold(current, resume);
  }

  /// Holds a suspended link for a resume: the banner, the heal timer that
  /// always fires, and the heal loop over every route.
  void _hold(SealedHostLink current, DesktopLinkResume resume) {
    _told = false;
    _liveness?.stop();
    resume.onHeld?.call(true);
    // The heal timer always fires: it is the one place that gives up.
    _heal = Timer(resume.grace, () {
      _tell(
        'link to ${resume.hostName} not resumed within '
        '${resume.grace.inSeconds}s; retired, redialling',
      );
      current.close('not resumed within the grace');
    });
    unawaited(_healLoop(current, resume));
  }

  Future<void> _healLoop(
    SealedHostLink current,
    DesktopLinkResume resume,
  ) async {
    var pass = 0;
    bool waiting() => !current.isClosed && current.suspended && !_released;
    while (waiting()) {
      List<DesktopResumeRoute> routes;
      try {
        routes = await resume.routes(generation);
      } on Object {
        routes = const [];
      }
      if (routes.isEmpty) {
        resume.onLog?.call(
          'link to ${resume.hostName}: no route to resume it over yet',
        );
      }
      for (final route in routes) {
        if (!waiting()) return;
        final outcome = await _tryRoute(current, route);
        if (outcome != null && !outcome.refused) {
          resume.onLog?.call(
            'resuming the link to ${resume.hostName} over ${route.path} at '
            '${route.label} failed: ${outcome.reason}',
          );
        }
        if (outcome == null) {
          _heal?.cancel();
          _afterProof?.cancel();
          // Back over a relay (the LAN went): promotable again when the LAN
          // returns.
          relayHost = route.relayHost;
          relay = route.relay;
          onRoute?.call(relay);
          _armLiveness();
          _tell(
            'resumed link to ${resume.hostName} over ${route.path} at '
            '${route.label} (generation $generation)',
          );
          return;
        }
        if (outcome.refused) {
          _heal?.cancel();
          _tell(
            '${resume.hostName} refused the resume (${outcome.reason}); '
            'redialling',
          );
          current.close('the server refused the resume: ${outcome.reason}');
          return;
        }
      }
      if (!waiting()) return;
      final wait =
          kDesktopResumeDelays[pass < kDesktopResumeDelays.length
              ? pass
              : kDesktopResumeDelays.length - 1];
      pass++;
      final woken = _healWake = Completer<void>();
      await Future.any<void>([
        Future<void>.delayed(wait),
        current.done,
        woken.future,
      ]);
      if (identical(_healWake, woken)) _healWake = null;
    }
  }

  void _wakeHeal() {
    final woken = _healWake;
    _healWake = null;
    if (woken != null && !woken.isCompleted) woken.complete();
  }

  /// The app came back, or the network changed (see
  /// [DesktopLinkResume.proofs]): a held link walks its routes now; a live
  /// one looks for the LAN and pings, and one that hears nothing back within
  /// [kDesktopProofWindow] is taken for dropped, so a resume runs over the
  /// routes there are now rather than after [kLinkDeadAfter].
  void _prove() {
    final resume = this.resume;
    final current = link;
    if (resume == null || current == null || current.isClosed || _released) {
      return;
    }
    if (current.suspended) {
      _wakeHeal();
      _endUnlessResumed(current, resume);
      return;
    }
    if (_attempt != null || _promoting || _transport == null) return;
    _maybePromote();
    if (_promoting || !_asks(resume.keepaliveOffered)) return;
    if (_proofWindow?.isActive ?? false) return;
    final before = _heard;
    current.ping();
    _proofWindow = Timer(kDesktopProofWindow, () {
      if (_heard != before || _released || current.isClosed) return;
      if (current.suspended || _attempt != null || _promoting) return;
      resume.onLog?.call(
        'link to ${resume.hostName} did not answer within '
        '${kDesktopProofWindow.inSeconds}s of a network change or a return '
        'to the app; taking its connection for dropped',
      );
      _dropped();
      if (current.suspended) _endUnlessResumed(current, resume);
    });
  }

  /// A held link someone is waiting on gets [DesktopLinkResume.afterProof]
  /// to resume, then is ended so its owners redial: the routes that resume
  /// it may not answer for the whole grace (a link held on this network
  /// while a phone was frozen), when a fresh dial lands at once.
  void _endUnlessResumed(SealedHostLink current, DesktopLinkResume resume) {
    if (_afterProof?.isActive ?? false) return;
    _afterProof = Timer(resume.afterProof, () {
      if (_released || current.isClosed || !current.suspended) return;
      _heal?.cancel();
      _tell(
        'link to ${resume.hostName} not resumed within '
        '${resume.afterProof.inSeconds}s of a network change or a return to '
        'the app; retired, redialling',
      );
      current.close('not resumed after a return');
    });
  }

  /// Says this suspension's outcome, once, and that the link is no longer
  /// held.
  void _tell(String message) {
    if (_told) return;
    _told = true;
    resume?.onLog?.call(message);
    resume?.onHeld?.call(false);
  }

  /// One resume over [route]. Null when the link is back; otherwise why not.
  Future<({bool refused, String reason})?> _tryRoute(
    SealedHostLink current,
    DesktopResumeRoute route,
  ) async {
    final RemoteTransport transport;
    try {
      transport = await route.open();
    } on Object catch (error) {
      route.noted?.call(false);
      return (refused: false, reason: '$error');
    }
    if (current.isClosed || _released) {
      await transport.close();
      return (refused: false, reason: 'the link ended');
    }
    final outcome = await _resumeOver(
      current,
      transport,
      timeout: route.timeout,
      adopting: true,
    );
    route.noted?.call(outcome == null || outcome.refused);
    return outcome;
  }

  /// One `link.resume` over [transport] — a fresh socket it [adopting]s, or
  /// the one already under [_transport] (a promotion's way back to its
  /// relay). Null when the link is back on it; otherwise why not, with the
  /// socket let go.
  Future<({bool refused, String reason})?> _resumeOver(
    SealedHostLink current,
    RemoteTransport transport, {
    required Duration timeout,
    required bool adopting,
  }) async {
    final attempt = _ResumeAttempt('resume-${++_attempts}');
    _attempt = attempt;
    if (adopting) {
      adopt(transport);
    } else if (transport.isConnected) {
      // Up all along: no state change will say so.
      attempt.connected();
    }
    final deadline = Timer(timeout, () {
      attempt.fail(
        attempt.isConnected
            ? 'the server did not answer there'
            : 'nothing could be reached there',
      );
    });
    // Sealed only once the socket is up: a resume frame takes a sequence the
    // server must step over, so one that could never go out is not spent.
    unawaited(
      attempt.whenConnected.then((_) async {
        if (attempt.isOver || !identical(_transport, transport)) return;
        try {
          transport.send(LinkHello(rendezvous, resume: true).encode());
        } on TransportException catch (error) {
          attempt.fail(error.message);
          return;
        }
        final sealed = await current.sealResume(
          (sequence, lastReceived, skip) => Envelope.of(
            FrameType.linkResume,
            seq: sequence,
            id: attempt.id,
            payload: {'lastReceived': lastReceived, 'skip': skip},
          ).toBytes(),
        );
        if (sealed == null) {
          attempt.fail(current.closeReason ?? 'the link ended');
          return;
        }
        if (attempt.isOver || !identical(_transport, transport)) return;
        try {
          transport.send(sealed);
        } on TransportException catch (error) {
          attempt.fail(error.message);
        }
      }),
    );
    final outcome = await attempt.outcome;
    deadline.cancel();
    if (identical(_attempt, attempt)) _attempt = null;
    if (outcome == null) return null;
    if (identical(_transport, transport)) await _detach(discard: true);
    return outcome;
  }

  /// The link is up and switched: the keepalive starts, and a link on a
  /// relay starts looking for the LAN.
  void started() {
    _armLiveness();
    final resume = this.resume;
    if (resume == null || _released) return;
    _proofs = resume.proofs?.listen((_) => _prove());
    if (resume.lanRoutes == null) return;
    _chances = resume.lanChances?.listen((_) => _maybePromote());
    _recheck = Timer.periodic(kDesktopPromotionRecheck, (_) => _maybePromote());
  }

  static bool _asks(bool Function()? question) {
    if (question == null) return false;
    try {
      return question();
    } on Object {
      return false;
    }
  }

  /// A chance to leave the relay (Stage 0 step 18): taken when the link is
  /// live on a relay, nothing else is moving it, the server offers both a
  /// resume and `link.promote`, and no failed promotion asked to wait.
  void _maybePromote() {
    final resume = this.resume;
    final lanRoutes = resume?.lanRoutes;
    final current = link;
    if (resume == null || lanRoutes == null || current == null) return;
    if (_released || _promoting || relayHost == null || _attempt != null) {
      return;
    }
    if (current.isClosed || current.suspended || _transport == null) return;
    final notBefore = _promoteNotBefore;
    if (notBefore != null && DateTime.now().isBefore(notBefore)) return;
    if (!_asks(resume.offered) || !_asks(resume.promoteOffered)) return;
    _promoting = true;
    unawaited(
      _promote(current, resume, lanRoutes).whenComplete(() {
        _promoting = false;
      }),
    );
  }

  bool _onRelay(SealedHostLink current) =>
      !_released &&
      relayHost != null &&
      !current.isClosed &&
      !current.suspended &&
      _attempt == null &&
      _transport != null;

  /// Make-before-break, the phone's order (`_dialStandbyLan`,
  /// `_adoptStandby`, `_rollBack`) over step 17's resume: a LAN socket is
  /// dialled alongside the relay, and only once it is up is the link moved
  /// onto it with a `link.resume`; the relay is let go only after the server
  /// has answered there. One socket per chance: the first route that
  /// connects is the one tried.
  Future<void> _promote(
    SealedHostLink current,
    DesktopLinkResume resume,
    Future<List<DesktopResumeRoute>> Function(int generation) lanRoutes,
  ) async {
    List<DesktopResumeRoute> routes;
    try {
      routes = await lanRoutes(generation);
    } on Object {
      return;
    }
    for (final route in routes) {
      if (!_onRelay(current)) return;
      // The machine IS the relay: a "direct" socket would reach the same
      // machine one hop shorter, over and over.
      if (route.address != null && route.address == relayHost) continue;
      final transport = await _openConnected(route);
      if (transport == null) continue;
      if (!_onRelay(current)) {
        await _closeQuietly(transport);
        return;
      }
      await _swap(current, resume, route, transport);
      return;
    }
  }

  /// Dials [route] and waits for its socket, within its timeout. Nothing
  /// is sent on it yet, and the link is not touched: a route that does not
  /// connect costs its cooldown, never a pause.
  Future<RemoteTransport?> _openConnected(DesktopResumeRoute route) async {
    final RemoteTransport transport;
    try {
      transport = await route.open();
    } on Object {
      route.noted?.call(false);
      return null;
    }
    try {
      await transport.states
          .firstWhere(
            (state) =>
                state == TransportState.connected ||
                state == TransportState.closed,
          )
          .timeout(route.timeout);
    } on Object {
      // Not up in time, or closed without connecting: said below.
    }
    if (transport.isConnected) return transport;
    route.noted?.call(false);
    await _closeQuietly(transport);
    return null;
  }

  /// Moves the link from its relay onto [transport], or back.
  Future<void> _swap(
    SealedHostLink current,
    DesktopLinkResume resume,
    DesktopResumeRoute route,
    RemoteTransport transport,
  ) async {
    final from = relayHost;
    // Writes wait in the retain window from here, and the relay is set aside
    // — open, but no longer read — so the resume's `lastReceived` is exactly
    // what was taken, and the server sends the rest again on the LAN.
    current.suspend();
    _liveness?.stop();
    _parked = (transport: _transport!, frames: _frames, states: _states);
    _transport = null;
    _frames = null;
    _states = null;
    final outcome = await _resumeOver(
      current,
      transport,
      timeout: route.timeout,
      adopting: true,
    );
    final parked = _parked;
    _parked = null;
    route.noted?.call(outcome == null || outcome.refused);
    if (outcome == null) {
      // Break: only now is the relay let go.
      relayHost = null;
      relay = null;
      onRoute?.call(null);
      _holdOff = Duration.zero;
      _promoteNotBefore = null;
      _armLiveness();
      if (parked != null) await _letGo(parked);
      resume.onLog?.call(
        'promoted link to ${resume.hostName} from relay $from to '
        '${route.path} at ${route.label} (generation $generation)',
      );
      return;
    }
    if (parked == null || _released || current.isClosed) {
      // Ended meanwhile: its owner, or [release], has let go of everything.
      if (parked != null) await _letGo(parked);
      return;
    }
    if (outcome.refused) {
      await _letGo(parked);
      resume.onLog?.call(
        'lan promotion of the link to ${resume.hostName} at ${route.label} '
        'was refused (${outcome.reason}); redialling',
      );
      current.close('the server refused the resume: ${outcome.reason}');
      return;
    }
    _holdOff = _holdOff == Duration.zero
        ? kDesktopPromotionHoldOff
        : (_holdOff * 2 > kDesktopPromotionHoldOffCap
              ? kDesktopPromotionHoldOffCap
              : _holdOff * 2);
    _promoteNotBefore = DateTime.now().add(_holdOff);
    // Roll back: the relay was never let go, so the link resumes on it — the
    // same resume, whether or not the server heard the one on the LAN.
    _transport = parked.transport;
    _frames = parked.frames;
    _states = parked.states;
    final back = await _resumeOver(
      current,
      parked.transport,
      timeout: kDesktopRollbackTimeout,
      adopting: false,
    );
    if (back == null) {
      _armLiveness();
      resume.onLog?.call(
        'lan promotion of the link to ${resume.hostName} at ${route.label} '
        'did not land (${outcome.reason}); kept on relay $from, next try in '
        '${_holdOff.inSeconds}s or later',
      );
      return;
    }
    if (back.refused) {
      resume.onLog?.call(
        'lan promotion of the link to ${resume.hostName} did not land '
        '(${outcome.reason}), and the relay refused it back '
        '(${back.reason}); redialling',
      );
      current.close('the server refused the resume: ${back.reason}');
      return;
    }
    // Neither socket took it: the heal loop walks every route, as after any
    // drop.
    resume.onLog?.call(
      'lan promotion of the link to ${resume.hostName} did not land '
      '(${outcome.reason}), and relay $from is gone too (${back.reason}); '
      'resuming it within ${resume.grace.inSeconds}s',
    );
    relayHost = null;
    relay = null;
    _hold(current, resume);
  }

  /// A set-aside relay is let go: no longer read, nothing stale flushed,
  /// closed.
  Future<void> _letGo(
    ({
      RemoteTransport transport,
      StreamSubscription<Uint8List>? frames,
      StreamSubscription<TransportState>? states,
    })
    parked,
  ) async {
    final transport = parked.transport;
    if (transport is ReconnectingTransport) transport.discardQueued();
    await parked.frames?.cancel();
    await parked.states?.cancel();
    await _closeQuietly(transport);
  }

  static Future<void> _closeQuietly(RemoteTransport transport) async {
    try {
      await transport.close();
    } on Object {
      // Already gone.
    }
  }

  /// With `link.keepalive`: an idle link pings, and one that hears nothing
  /// for [kLinkDeadAfter] — a half-open socket, which TCP may never report —
  /// is treated as dropped, so step 17's resume runs. Restarted on every
  /// move; stopped while the link is held.
  void _armLiveness() {
    final resume = this.resume;
    if (resume == null || resume.keepaliveOffered == null || _released) {
      return;
    }
    final liveness = _liveness ??= LinkLiveness(
      onPing: () {
        final current = link;
        if (current == null || current.isClosed || current.suspended) return;
        if (_asks(resume.keepaliveOffered)) current.ping();
      },
      onDead: _silent,
    );
    liveness
      ..stop()
      ..start();
  }

  void _silent(Duration silence) {
    final resume = this.resume;
    final current = link;
    if (resume == null || current == null || current.isClosed || _released) {
      return;
    }
    // A server that answers no ping: its silence proves nothing.
    if (!_asks(resume.keepaliveOffered)) {
      _liveness?.start();
      return;
    }
    // Moving already; whatever moves it restarts the count.
    if (current.suspended || _attempt != null || _promoting) {
      _liveness?.start();
      return;
    }
    resume.onLog?.call(
      'link to ${resume.hostName} heard nothing for ${silence.inSeconds}s; '
      'taking its connection for dropped',
    );
    _dropped();
  }

  /// The first frame on a resuming socket: the server's answer.
  Future<void> _onResumeAnswer(
    _ResumeAttempt attempt,
    RemoteTransport transport,
    SealedFrame opened,
  ) async {
    // Given up on while the frame was being opened: that socket is gone.
    if (attempt.isOver || !identical(_transport, transport)) return;
    final current = link;
    Envelope? envelope;
    try {
      envelope = Envelope.fromBytes(opened.plaintext, accept: VersionRange.any);
    } on ProtocolException {
      envelope = null;
    }
    if (current == null) {
      attempt.fail('the link ended');
      return;
    }
    if (envelope == null || envelope.id != attempt.id) {
      // Not the answer: what the server sent before it heard the resume,
      // still draining out of a socket the link is going back to (a
      // promotion's rollback onto its relay). The server sends it again
      // after the answer, where it must open once more; the deadline still
      // bounds the wait.
      channel.forget(opened.sequence);
      return;
    }
    if (envelope.knownType == FrameType.error) {
      final message = envelope.payload['message'];
      attempt.refuse(message is String ? message : 'refused');
      return;
    }
    final payload = envelope.payload;
    final last = payload['lastReceived'];
    final skip = payload['skip'];
    if (envelope.knownType != FrameType.result ||
        payload['resumed'] != true ||
        last is! int) {
      attempt.fail('the server\'s answer could not be read');
      return;
    }
    // Taken: from here the deadline no longer applies, and the frames after
    // this one are the link's own.
    attempt.answered();
    _attempt = null;
    final resumed = await current.completeResume(
      peerLastReceived: last,
      peerAnswerSequence: opened.sequence,
      peerSkip: [
        if (skip is List)
          for (final s in skip.take(kHostLinkMaxResumeFrames))
            if (s is int) s,
      ],
    );
    if (resumed) {
      attempt.succeed();
    } else {
      attempt.refuse(current.closeReason ?? 'the answer could not be taken');
    }
  }
}

/// One `link.resume` over one socket.
class _ResumeAttempt {
  _ResumeAttempt(this.id);

  final String id;
  final _connected = Completer<void>();
  final _outcome = Completer<({bool refused, String reason})?>();
  var _answered = false;

  bool get isConnected => _connected.isCompleted;
  bool get isOver => _outcome.isCompleted;
  Future<void> get whenConnected => _connected.future;
  Future<({bool refused, String reason})?> get outcome => _outcome.future;

  void connected() {
    if (!_connected.isCompleted) _connected.complete();
  }

  /// The answer arrived: nothing but its own outcome ends this attempt now.
  void answered() => _answered = true;

  void succeed() {
    if (!_outcome.isCompleted) _outcome.complete(null);
  }

  void refuse(String reason) {
    if (!_outcome.isCompleted) {
      _outcome.complete((refused: true, reason: reason));
    }
  }

  void fail(String reason) {
    if (_answered || _outcome.isCompleted) return;
    _outcome.complete((refused: false, reason: reason));
  }
}

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
