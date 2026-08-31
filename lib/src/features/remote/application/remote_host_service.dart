/// The host side of remote access: per paired device, a sealed channel bound
/// to the current rendezvous generation, listened for over the relay and over
/// the LAN, with revocation enforced and counters persisted.
///
/// OFF by default — nothing constructs this until the settings toggle asks
/// for it, and `AppLifecycle` tears it down inside its budget slice.
///
/// ## Generation policy (the loop-64 drift rule, made concrete)
///
/// The device row persists ONE counter. The host listens on the relay at the
/// counter and the next few after it ([kHostRelayListenWindow]); the LAN hello
/// is matched against the same window. The companion dials its own counter and
/// probes forward. Whichever generation actually carries traffic is adopted
/// and persisted, and the window slides up; generations below it are closed.
/// The companion bumps its counter after a session pairs, so successive
/// sessions land on fresh rendezvous ids and freshly keyed channels, while a
/// reconnect inside a session finds the same generation — and the same
/// sequence numbers — still there.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../data/paired_device_dao.dart';
import '../domain/paired_device.dart';
import '../pairing/host_pairing.dart';
import '../pairing/pairing_payload.dart';
import '../pairing/pairing_wire.dart';
import '../protocol.dart';
import '../push/push_fanout.dart';
import '../push/relay_push_client.dart';
import '../transport/key_schedule.dart';
import '../transport/lan_beacon.dart';
import '../transport/lan_transport.dart';
import '../transport/relay_transport.dart';
import '../transport/remote_transport.dart';
import '../transport/sealed_channel.dart';
import 'host_bindings.dart';
import 'host_session_api.dart';

/// How many consecutive generations the host listens on per device. Covers a
/// companion whose counter ran ahead (it bumps after pairing; the host adopts
/// on traffic); a companion *behind* probes forward on its own side. Drift
/// beyond the window means a restored backup — re-pair.
const int kHostRelayListenWindow = 3;

/// Builds the relay listener for one rendezvous. A seam: tests point it at an
/// in-process relay, or swap the transport entirely.
typedef RelayTransportFactory =
    RemoteTransport Function(Uri relay, RendezvousId rendezvous);

class RemoteHostService {
  RemoteHostService({
    required this.devices,
    required this.hostId,
    required this.bindings,
    required this.relay,
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
       // ignore: prefer_initializing_formals — private field, named for callers.
       _pushPost = pushPost;

  static RemoteTransport _defaultRelayFactory(
    Uri relay,
    RendezvousId rendezvous,
  ) => RelayTransport.connect(relay: relay, rendezvous: rendezvous);

  final PairedDeviceDao devices;
  final DeviceId hostId;
  final RemoteHostBindings bindings;

  /// The relay base URL (settings; the PopupBits default unless changed).
  final Uri relay;

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

  /// Sealed, best-effort push fan-out for devices with no live link.
  late final PushFanout _pushFanout = PushFanout(
    devices: devices.getActive,
    hasLiveLink: hasLiveLink,
    client: RelayPushClient(relay: relay, post: _pushPost, onLog: onLog),
    now: _now,
    onLog: onLog,
  );

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

  // --- Pairing ---------------------------------------------------------------

  /// Shows a new QR: generates the payload, listens on its rendezvous over
  /// the relay (LAN links route by hello), and persists the device once the
  /// sealed round-trip proves the key. One pairing at a time; a new call
  /// cancels the previous code. [relay] overrides the service's own for this
  /// one code — the pairing dialog's endpoint choice (local vs internet).
  Future<HostPairingSession> beginPairing({
    required CapabilitySet capabilities,
    Uri? relay,
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
    );
    final session = HostPairingSession(
      payload: payload,
      hostName: bindings.hostName,
      now: _now,
      persist: (device) async {
        devices.insert(device);
        onDevicesChanged?.call();
        await _ensureRuntime(device);
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

  // --- Revocation ------------------------------------------------------------

  /// Deletes the device's key, tears down its channels and stops listening
  /// for it. Its frames are junk from here on: nothing holds a key that can
  /// open them.
  Future<void> revoke(String deviceId) async {
    devices.revoke(deviceId);
    final runtime = _runtimes.remove(deviceId);
    if (runtime != null) await runtime.close();
    _lanRoutes.removeWhere((_, route) => route.deviceId == deviceId);
    onDevicesChanged?.call();
  }

  // --- Event fan-out ---------------------------------------------------------

  /// Something about sessions moved; every connected device re-evaluates its
  /// subscriptions.
  Future<void> notifySessionsChanged() async {
    await Future.wait([
      for (final runtime in _runtimes.values.toList())
        runtime.run((api) => api.pushSessionsChanged()),
    ]);
  }

  /// A session started waiting for approval; devices holding `approve` hear
  /// about it with the Loop-49 evidence.
  Future<void> notifyApprovalRequested(String sessionId) async {
    await Future.wait([
      for (final runtime in _runtimes.values.toList())
        runtime.run((api) => api.pushApprovalRequested(sessionId)),
    ]);
  }

  /// Whether [deviceId]'s phone can hear events right now: a frame arrived on
  /// its active link since the carrying transport last dropped. (The relay
  /// closes the host's socket when the peer leaves, so a phone that walked
  /// away is noticed.)
  bool hasLiveLink(String deviceId) => _runtimes[deviceId]?.peerLive ?? false;

  /// Attention news for the phones that are NOT connected: sealed per device
  /// and posted to the relay's `/v1/push`. A connected phone hears the same
  /// news as `session.changed` — never both. Best-effort; never throws.
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

  /// One transcript poll across every device, now. The periodic timer calls
  /// this; tests call it directly.
  Future<void> pollTranscriptsNow() async {
    await Future.wait([
      for (final runtime in _runtimes.values.toList())
        runtime.run((api) => api.pollTranscripts()),
    ]);
  }

  // --- Wiring ----------------------------------------------------------------

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

/// Everything live for one paired device: its relay listeners across the
/// generation window, and — once traffic arrives — the sealed channel, the
/// session api and the transport that carries its frames.
class _DeviceRuntime {
  _DeviceRuntime(this.service, this.device, this.key);

  final RemoteHostService service;
  PairedDevice device;
  final SecretKeyData key;

  final Map<int, RemoteTransport> _listeners = {};
  final Map<int, StreamSubscription<Uint8List>> _listenerSubscriptions = {};
  final Map<int, String> _rendezvousHexByGeneration = {};

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

  /// Opens relay listeners for `[from, from + window)` and closes anything
  /// below — the sliding window of the generation policy.
  Future<void> listenFrom(int from) async {
    if (_closed) return;
    for (var g = from; g < from + kHostRelayListenWindow; g++) {
      if (_listeners.containsKey(g)) continue;
      final rendezvous = await rendezvousFor(key, g);
      _rendezvousHexByGeneration[g] = rendezvous.value;
      service._lanRoutes[rendezvous.value] = (
        deviceId: device.id,
        generation: g,
      );
      final transport = service._relayFactory(service.relay, rendezvous);
      _listeners[g] = transport;
      _listenerSubscriptions[g] = transport.frames.listen(
        (frame) => enqueueFrame(g, transport, frame),
      );
    }
    for (final g in _listeners.keys.toList()) {
      if (g >= from) continue;
      await _closeListener(g);
    }
  }

  Future<void> _closeListener(int generation) async {
    final hex = _rendezvousHexByGeneration.remove(generation);
    if (hex != null) service._lanRoutes.remove(hex);
    await _listenerSubscriptions.remove(generation)?.cancel();
    final transport = _listeners.remove(generation);
    if (transport != null) await transport.close();
  }

  Future<void> _onFrame(
    int generation,
    RemoteTransport transport,
    Uint8List frame,
  ) async {
    if (_closed) return;
    // Revocation is enforced at the door: a revoked row has no key, and its
    // frames are dropped before anything tries to answer them.
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
    } on SealedChannelException catch (error) {
      service.onLog?.call('refused a frame: $error');
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
    // new socket — the conformance fixture's rule.
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

  Future<void> _sealAndSend(
    _ActiveLink active,
    FrameType type,
    String? id,
    Map<String, Object?> payload,
  ) async {
    if (_closed || _active != active) return;
    // No awaits between reading the sequence and sealing: the two must agree,
    // and every caller is already serialised on the device chain.
    final envelope = Envelope.of(
      type,
      seq: active.channel.nextSendSequence,
      id: id,
      payload: payload,
    );
    final sealed = await active.channel.seal(envelope.toBytes());
    try {
      active.transport.send(sealed);
    } on TransportException {
      // The link the phone last used is gone; the relay listener for this
      // generation still queues for the next reconnect.
      final fallback = _listeners[active.generation];
      if (fallback != null && !identical(fallback, active.transport)) {
        try {
          fallback.send(sealed);
        } on TransportException {
          service.onLog?.call('no transport could carry a frame');
        }
      }
    }
  }

  Future<void> close() async {
    _closed = true;
    peerLive = false;
    await _liveWatch?.cancel();
    _liveWatch = null;
    _watchedTransport = null;
    for (final generation in _listeners.keys.toList()) {
      await _closeListener(generation);
    }
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
