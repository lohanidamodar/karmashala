/// The host side of remote access: per device, a sealed channel bound to its
/// rendezvous generation, heard over relay and LAN. OFF until the toggle asks.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:karmashala_store/devices.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/push.dart';
import 'package:karmashala_remote/host.dart';

/// How many consecutive generations the host listens on per device. Drift
/// beyond the window means a restored backup — re-pair.
const int kHostRelayListenWindow = 3;

/// Builds the relay listener for one rendezvous — a seam tests point at an
/// in-process relay.
typedef RelayTransportFactory =
    RemoteTransport Function(Uri relay, RendezvousId rendezvous);

class RemoteHostService {
  RemoteHostService({
    required this.devices,
    required this.hostId,
    required this.bindings,
    required this.relay,
    Uri? localRelayUrl,
    bool hostedEnabled = true,
    List<Uri> extraRelays = const [],
    this.lanPort = kDefaultLanPort,
    this.advertise = true,
    this.transcriptPollInterval = const Duration(seconds: 2),
    DateTime Function()? now,
    RelayTransportFactory? relayFactory,
    PushPost? pushPost,
    this.onDevicesChanged,
    this.onLog,
  }) : _now = now ?? DateTime.now,
       _relayFactory = relayFactory ?? _defaultRelayFactory,
       // ignore: prefer_initializing_formals — private fields, named for callers.
       _localRelayUrl = localRelayUrl,
       // ignore: prefer_initializing_formals — same.
       _hostedEnabled = hostedEnabled,
       _extraRelays = List.unmodifiable(extraRelays),
       // ignore: prefer_initializing_formals — same.
       _pushPost = pushPost;

  static RemoteTransport _defaultRelayFactory(
    Uri relay,
    RendezvousId rendezvous,
  ) => RelayTransport.connect(relay: relay, rendezvous: rendezvous);

  final PairedDeviceDao devices;
  final DeviceId hostId;
  final RemoteHostBindings bindings;

  /// The configured hosted relay: the fallback for a device row whose stored
  /// relay is absent or unreadable, and the default pairing relay.
  final Uri relay;

  /// Where the embedded local relay can be dialled right now, or null while
  /// it is stopped — local-relay devices are parked then.
  Uri? _localRelayUrl;

  bool _hostedEnabled;

  /// Relays this desktop runs on its own SSH hosts. Served through whatever the
  /// other two switches say: a meeting place of the user's own.
  List<Uri> _extraRelays;

  Uri? get localRelayUrl => _localRelayUrl;
  bool get hostedEnabled => _hostedEnabled;
  List<Uri> get extraRelays => _extraRelays;

  final int lanPort;

  /// Whether to run the multicast beacon. Off in tests — the LAN listener
  /// itself is plain loopback-friendly TCP.
  final bool advertise;

  /// How often subscribed transcripts are re-read. [Duration.zero] disables
  /// the timer; tests call [pollTranscriptsNow] themselves.
  final Duration transcriptPollInterval;

  final DateTime Function() _now;
  final RelayTransportFactory _relayFactory;

  /// Posts push JSON to the relay — a seam so tests never touch a network.
  /// Null means the real HTTP poster.
  final PushPost? _pushPost;

  /// Sealed, best-effort push fan-out for devices with no live link. Each
  /// push POSTs to the device's OWN relay — never to one it cannot hear.
  late final PushFanout _pushFanout = PushFanout(
    devices: devices.getActive,
    hasLiveLink: hasLiveLink,
    clientFor: _pushClientFor,
    now: _now,
    onLog: onLog,
  );

  final Map<String, RelayPushClient> _pushClients = {};

  RelayPushClient? _pushClientFor(PairedDevice device) {
    final url = relayUrlFor(device);
    if (url == null) return null;
    try {
      return _pushClients[url.toString()] ??= RelayPushClient(
        relay: url,
        post: _pushPost,
        onLog: onLog,
      );
    } on ArgumentError {
      return null; // An unusable scheme cannot carry a push.
    }
  }

  /// The relay [device]'s **pushes** go to: the one it paired through, the only
  /// relay its phone is known to poll. Null while that relay is off.
  Uri? relayUrlFor(PairedDevice device) {
    if (device.pairedViaLocalRelay) return _localRelayUrl;
    final own = device.hostedRelayUri;
    // A relay on a box forwards frames and nothing else: it holds no FCM
    // credentials, so a push handed to it goes nowhere. The push is this
    // desktop's POST, not the phone's, so the hosted relay can carry it.
    if (own != null && _isExtraRelay(own)) return _hostedEnabled ? relay : null;
    if (!_hostedEnabled) return null;
    return own ?? relay;
  }

  bool _isExtraRelay(Uri url) =>
      _extraRelays.any((extra) => extra.toString() == url.toString());

  /// Listens on every active relay for [device], not just the paired one: the
  /// rendezvous comes from the device key, so only that phone can meet it.
  List<Uri> activeRelayUrlsFor(PairedDevice device) {
    final urls = <String, Uri>{};
    final local = _localRelayUrl;
    if (local != null) urls[local.toString()] = local;
    for (final extra in _extraRelays) {
      urls[extra.toString()] = extra;
    }
    if (_hostedEnabled) {
      // Plus the configured relay, so a phone falling back to the app default
      // still finds somebody listening.
      final own = device.hostedRelayUri;
      if (own != null) urls[own.toString()] = own;
      urls[relay.toString()] = relay;
    }
    return List.unmodifiable(urls.values);
  }

  /// The relay set announced in `host.status` — the same list the listeners are
  /// open on, so a phone is never told about a relay nobody is waiting at.
  List<Uri> announcedRelaysFor(PairedDevice device) =>
      activeRelayUrlsFor(device);

  /// `host:port` of the direct LAN listener — a hint for a network that eats
  /// multicast; loopback is never announced and DHCP can make it stale.
  String? get lanHint {
    final port = _lanServer?.port;
    final host = _localRelayUrl?.host;
    if (port == null || host == null || host.isEmpty) return null;
    if (host == '127.0.0.1' || host == 'localhost' || host == '::1') {
      return null;
    }
    return '$host:$port';
  }

  /// Points the service at the currently active relays and tells every live
  /// phone the new set, so its saved candidates heal without a re-pair.
  Future<void> updateRelays({
    required Uri? localRelayUrl,
    required bool hostedEnabled,
    List<Uri>? extraRelays,
  }) async {
    final extras = extraRelays ?? _extraRelays;
    if (_localRelayUrl == localRelayUrl &&
        _hostedEnabled == hostedEnabled &&
        _sameRelays(extras, _extraRelays)) {
      return;
    }
    _localRelayUrl = localRelayUrl;
    _hostedEnabled = hostedEnabled;
    _extraRelays = List.unmodifiable(extras);
    // The announcement goes FIRST, on the links still up: re-pointing the
    // listeners closes the very socket a connected phone is holding.
    await Future.wait([
      for (final runtime in _runtimes.values.toList())
        runtime.run((api) => api.sendHostStatus()),
    ]);
    for (final runtime in _runtimes.values.toList()) {
      await runtime.syncRelayListeners();
    }
  }

  static bool _sameRelays(List<Uri> a, List<Uri> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].toString() != b[i].toString()) return false;
    }
    return true;
  }

  /// Fired when the device list changed (paired, revoked, seen).
  final void Function()? onDevicesChanged;
  final void Function(String message)? onLog;

  final Map<String, _DeviceRuntime> _runtimes = {};

  /// rendezvous hex → which device+generation a LAN hello names.
  final Map<String, ({String deviceId, int generation})> _lanRoutes = {};

  LanTransportServer? _lanServer;
  StreamSubscription<LanLink>? _lanConnections;
  LanBeacon? _beacon;
  HostPairingSession? _pairing;
  RemoteTransport? _pairingTransport;
  Timer? _transcriptTimer;
  bool _started = false;

  bool get isRunning => _started;

  /// Where the LAN listener actually bound, once running.
  int? get lanPortBound => _lanServer?.port;

  HostPairingSession? get activePairing => _pairing;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      _lanServer = await LanTransportServer.bind(port: lanPort, onLog: onLog);
    } on SocketException {
      // The preferred port is taken; any port works — the beacon carries it.
      _lanServer = await LanTransportServer.bind(port: 0, onLog: onLog);
    }
    _lanConnections = _lanServer!.connections.listen(_acceptLanLink);
    if (advertise) {
      _beacon = await LanBeacon.advertise(
        port: _lanServer!.port,
        tag: LanAdvert.newTag(),
      );
    }
    for (final device in devices.getActive()) {
      await _ensureRuntime(device);
    }
    if (transcriptPollInterval > Duration.zero) {
      _transcriptTimer = Timer.periodic(
        transcriptPollInterval,
        (_) => pollTranscriptsNow(),
      );
    }
  }

  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    _transcriptTimer?.cancel();
    _transcriptTimer = null;
    _beacon?.stop();
    _beacon = null;
    await cancelPairing();
    await _lanConnections?.cancel();
    _lanConnections = null;
    await _lanServer?.close();
    _lanServer = null;
    for (final runtime in _runtimes.values.toList()) {
      await runtime.close();
    }
    _runtimes.clear();
    _lanRoutes.clear();
  }

  /// Shows a new QR and persists the device once the sealed round-trip proves
  /// its key. [relayIsLocal] stores [kLocalRelayMarker], not a LAN URL.
  Future<HostPairingSession> beginPairing({
    required CapabilitySet capabilities,
    Uri? relay,
    bool relayIsLocal = false,
  }) async {
    if (!_started) {
      throw StateError('remote access is not running');
    }
    await cancelPairing();
    final pairingRelay = relay ?? this.relay;
    final payload = await PairingPayload.generateWithCode(
      relay: pairingRelay,
      hostId: hostId,
      capabilities: capabilities,
      // The tab's relay stays the payload's `relay` — an older companion reads
      // that alone — while the QR names every other relay this host serves.
      relays: [?_localRelayUrl, ..._extraRelays, if (_hostedEnabled) this.relay],
    );
    final session = HostPairingSession(
      payload: payload,
      hostName: bindings.hostName,
      now: _now,
      persist: (device) async {
        final stamped = device.copyWith(
          relayUrl: relayIsLocal ? kLocalRelayMarker : pairingRelay.toString(),
        );
        devices.insert(stamped);
        onDevicesChanged?.call();
        await _rebuildRuntime(stamped);
      },
    );
    _pairing = session;
    final transport = _relayFactory(pairingRelay, payload.rendezvous);
    _pairingTransport = transport;
    session.attach(transport);
    unawaited(
      session.done
          .then((_) {}, onError: (_) {})
          .whenComplete(() => _finishPairing(session)),
    );
    return session;
  }

  Future<void> cancelPairing() async {
    final pairing = _pairing;
    final transport = _pairingTransport;
    _pairing = null;
    _pairingTransport = null;
    if (pairing != null) await pairing.close();
    if (transport != null) await transport.close();
  }

  Future<void> _finishPairing(HostPairingSession session) async {
    if (_pairing != session) return;
    // Let the sealed done frame drain before the socket goes away.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (_pairing != session) return;
    await cancelPairing();
  }

  /// Deletes the device's key, tears down its channels and stops listening for
  /// it. Its frames are junk from here on: nothing holds a key that opens them.
  Future<void> revoke(String deviceId) async {
    devices.revoke(deviceId);
    final runtime = _runtimes.remove(deviceId);
    if (runtime != null) {
      // Said before the link is taken away, because afterwards there is nothing
      // to say it on.
      try {
        await runtime.run((api) => api.sendPairingRevoked());
      } on Object catch (error) {
        onLog?.call('could not tell the device it was revoked: $error');
      }
      await runtime.close();
    }
    _lanRoutes.removeWhere((_, route) => route.deviceId == deviceId);
    onDevicesChanged?.call();
  }

  /// Something about sessions moved; every connected device re-evaluates its
  /// subscriptions.
  Future<void> notifySessionsChanged() async {
    await Future.wait([
      for (final runtime in _runtimes.values.toList())
        runtime.sweepSessionsChanged(),
    ]);
  }

  /// A session started waiting for approval; devices holding `approve` hear
  /// about it.
  Future<void> notifyApprovalRequested(String sessionId) async {
    await Future.wait([
      for (final runtime in _runtimes.values.toList())
        runtime.run((api) => api.pushApprovalRequested(sessionId)),
    ]);
  }

  /// Whether [deviceId]'s phone can hear events right now: a frame arrived on
  /// its active link since the carrying transport last dropped.
  bool hasLiveLink(String deviceId) => _runtimes[deviceId]?.peerLive ?? false;

  /// Whether [deviceId] is parked: its relays are off, so only a direct LAN
  /// link reaches it. It resumes when one returns — no re-pair.
  bool isParked(String deviceId) => _runtimes[deviceId]?.parked ?? false;

  /// Attention news for phones with no live link, sealed per device and posted
  /// to their relay; a connected phone hears `session.changed`. Never throws.
  Future<void> pushAttentionNews({
    required String sessionId,
    required String title,
    required String kind,
  }) async {
    if (!_started) return;
    try {
      await _pushFanout.notifyAttention(
        sessionId: sessionId,
        title: title,
        kind: kind,
      );
    } on Object catch (error) {
      onLog?.call('push fan-out failed: ${error.runtimeType}');
    }
  }

  /// One transcript poll across every device, now. A device already sweeping
  /// swallows the tick — see [_DeviceRuntime.sweepTranscripts].
  Future<void> pollTranscriptsNow() async {
    await Future.wait([
      for (final runtime in _runtimes.values.toList())
        runtime.sweepTranscripts(),
    ]);
  }

  /// Replaces whatever was listening for [device] after a re-pair: a new key
  /// means a new rendezvous series, so nothing is carried across.
  Future<void> _rebuildRuntime(PairedDevice device) async {
    final previous = _runtimes.remove(device.id);
    if (previous != null) await previous.close();
    await _ensureRuntime(device);
  }

  Future<void> _ensureRuntime(PairedDevice device) async {
    if (!_started) return;
    if (device.deviceKey.isEmpty || device.revoked) return;
    if (_runtimes.containsKey(device.id)) return;
    final runtime = _DeviceRuntime(
      this,
      device,
      SecretKeyData(Uint8List.fromList(device.deviceKey)),
    );
    _runtimes[device.id] = runtime;
    await runtime.listenFrom(device.generation);
  }

  void _acceptLanLink(LanLink link) {
    // Until the hello arrives nobody owns this link; route on first frame.
    _LanRoute? route;
    late final StreamSubscription<Uint8List> subscription;
    subscription = link.frames.listen((frame) {
      final current = route;
      if (current != null) {
        current.forward(frame);
        return;
      }
      final hello = LinkHello.tryDecode(frame);
      if (hello == null) {
        onLog?.call('lan link opened with something other than a hello');
        subscription.cancel();
        link.close();
        return;
      }
      final hex = hello.rendezvous.value;
      final pairing = _pairing;
      if (pairing != null && pairing.payload.rendezvous.value == hex) {
        route = _LanRoute((f) => pairing.handleFrame(link, f));
        pairing.handleFrame(link, frame);
        return;
      }
      final target = _lanRoutes[hex];
      if (target == null) {
        onLog?.call('lan hello for an unknown rendezvous');
        subscription.cancel();
        link.close();
        return;
      }
      final runtime = _runtimes[target.deviceId];
      if (runtime == null) {
        onLog?.call('lan hello for a device with no runtime');
        subscription.cancel();
        link.close();
        return;
      }
      route = _LanRoute(
        (f) => runtime.enqueueFrame(target.generation, link, f),
      );
      runtime.enqueueFrame(target.generation, link, frame);
    });
  }
}

class _LanRoute {
  _LanRoute(this.forward);

  final void Function(Uint8List frame) forward;
}

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

  RemoteTransport? _watchedTransport;
  StreamSubscription<TransportState>? _liveWatch;

  /// Serialises everything for this device — frames, event pushes, seals — so
  /// `Envelope.seq` always matches the sealed sequence.
  Future<void> _chain = Future<void>.value();

  /// What this phone's `session.start` frames produced. Held here, not on the
  /// api, because the retry it exists for arrives on a fresh generation.
  final SessionStartLedger<RemoteSessionStarted> _starts = SessionStartLedger<RemoteSessionStarted>();
  final SessionStartLedger<RemoteSessionStarted> _resumes = SessionStartLedger<RemoteSessionStarted>();
  final SessionStartLedger<RemoteWorkspaceProject> _projects = SessionStartLedger<RemoteWorkspaceProject>();
  final SessionStartLedger<RemotePromptDelivery> _prompts = SessionStartLedger<RemotePromptDelivery>();

  bool _sweeping = false;

  /// One transcript sweep for this device, never two at once: a sweep outlasts
  /// the poll interval, and queued ticks grew the chain faster than it drained.
  Future<void> sweepTranscripts() async {
    if (_sweeping || _closed) return;
    _sweeping = true;
    try {
      for (final sessionId
          in _active?.api.subscribedSessions ?? const <String>{}) {
        if (_closed) return;
        await run((api) => api.pollTranscript(sessionId));
        await run((api) => api.recheckApproval(sessionId));
      }
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
          if (_closed) return;
          await run((api) => api.pushSessionChanged(sessionId));
        }
        // And any session this phone has never been shown, which no
        // subscription covers yet.
        if (!_closed) await run((api) => api.pushNewSessions());
      } while (_pushAgain && !_closed);
    } finally {
      _pushing = false;
      _pushAgain = false;
    }
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
      if (g >= from) continue;
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
    if (_active?.generation != generation) return;
    _retired.add(generation);
    _active = null;
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
    for (final url in _listeners[generation]?.keys.toList() ?? const <String>[]) {
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
    // A retired generation is over: anything still draining out of it must not
    // walk the window back down — `_activate` would happily re-open it.
    if (_retired.contains(generation)) return;
    // Revocation is enforced at the door: a revoked row has no key.
    final current = service.devices.getById(device.id);
    if (current == null || current.revoked) return;

    if (LinkHello.tryDecode(frame) != null) {
      await _activate(generation, transport, announce: true);
      peerLive = true;
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
    } on SealedChannelException catch (error) {
      // The tag verified but the sequence repeats: the channel cannot be reset
      // — its replay window is the only guard — so the generation is retired.
      service.onLog?.call('retiring generation $generation: $error');
      await _retireGeneration(generation);
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
    await active.api.handleEnvelope(envelope);
  }

  /// Tracks whether the transport carrying the active link is up. Only a
  /// frame proves the *phone* is there; a drop proves it may not be.
  void _watchLiveness(RemoteTransport transport) {
    if (identical(_watchedTransport, transport)) return;
    _liveWatch?.cancel();
    _watchedTransport = transport;
    _liveWatch = transport.states.listen((state) {
      if (state != TransportState.connected) peerLive = false;
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
        send: (type, {id, payload = const {}}) =>
            _sealAndSend(created, type, id, payload),
      );
      created = _ActiveLink(generation, channel, api, transport);
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
    if (announce) await active.api.sendHostStatus();
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

  Future<void> close() async {
    _closed = true;
    peerLive = false;
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
    for (final generation in _rendezvousHexByGeneration.keys.toList()) {
      _closeGeneration(generation);
    }
    _listenerUrls = const [];
    _active = null;
  }
}

class _ActiveLink {
  _ActiveLink(this.generation, this.channel, this.api, this.transport);

  final int generation;
  final SealedChannel channel;
  final HostSessionApi api;
  RemoteTransport transport;
}
