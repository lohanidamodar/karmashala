/// The companion server: per device, a sealed channel bound to its rendezvous
/// generation, heard over relay and LAN. Run by the session host whenever there
/// is one, and by the desktop app only where there is none.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/push.dart';
import 'package:karmashala_remote/host.dart';

part 'remote_host_service/device_runtime.dart';

/// How many consecutive generations the host listens on per device. Drift
/// beyond the window means a restored backup — re-pair.
const int kHostRelayListenWindow = 3;

/// How many desktop links one server keeps suspended for a `link.resume` at
/// once. Each holds its retain window (at most `kHostLinkRetainBytes`) and its
/// client's write tokens for up to the grace; past the cap a drop is today's
/// teardown.
const int kMaxSuspendedHostLinks = 8;

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
    this.lanAddress = '0.0.0.0',
    this.lanHost,
    this.advertise = true,
    this.transcriptPollInterval = const Duration(seconds: 2),
    this.newStreamFlow = StreamFlow.new,
    this.watchLease = kWatchLease,
    this.linkDeadAfter = kHostLinkDeadAfter,
    this.linkResumeGrace = kHostLinkResumeGrace,
    DateTime Function()? now,
    RelayTransportFactory? relayFactory,
    PushPost? pushPost,
    this.onDevicesChanged,
    this.onHostLink,
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

  final PairedDeviceStore devices;
  final DeviceId hostId;
  final RemoteHostBindings bindings;

  /// The configured hosted relay: the fallback for a device row whose stored
  /// relay is absent or unreadable, and the default pairing relay. Null on a
  /// machine that meets phones only where each row says — a box: a phone
  /// paired straight to its address then costs no outbound connection, and a
  /// pairing with no relay named is a direct one.
  final Uri? relay;

  /// Where the local relay can be dialled right now, or null while it is
  /// stopped — local-relay devices are parked then.
  Uri? _localRelayUrl;

  bool _hostedEnabled;

  /// Relays this desktop runs on its own SSH hosts. Served through whatever the
  /// other two switches say: a meeting place of the user's own.
  List<Uri> _extraRelays;

  Uri? get localRelayUrl => _localRelayUrl;
  bool get hostedEnabled => _hostedEnabled;
  List<Uri> get extraRelays => _extraRelays;

  final int lanPort;

  /// The address the LAN listener binds: every interface by default (a
  /// desktop's phones on its network), loopback or one interface when the
  /// server's config says so. The listener carries only the sealed
  /// protocol; this narrows who can knock, not what they can do.
  final Object lanAddress;

  /// The address a phone on this network reaches the LAN listener at, when
  /// the host knows one without a local relay to read it from.
  final String? lanHost;

  /// Whether to run the multicast beacon. Off in tests — the LAN listener
  /// itself is plain loopback-friendly TCP.
  final bool advertise;

  /// How often subscribed transcripts are re-read. [Duration.zero] disables
  /// the timer; tests call [pollTranscriptsNow] themselves.
  final Duration transcriptPollInterval;

  /// Builds each link's flow control — a seam so tests can shrink its limits.
  final StreamFlow Function() newStreamFlow;

  /// How long a phone's "watching" holds without renewal.
  final Duration watchLease;

  /// Silence after which a phone that pings is dropped — see [LinkLiveness].
  final Duration linkDeadAfter;

  /// How long a desktop client's switched link outlives its socket, waiting
  /// for a `link.resume` (Stage 0 step 16).
  final Duration linkResumeGrace;

  /// Desktop links held for a resume right now, across every device.
  int get _suspendedHostLinks => _runtimes.values
      .where((runtime) => runtime._active?.host?.suspended ?? false)
      .length;

  final DateTime Function() _now;
  final RelayTransportFactory _relayFactory;

  /// Posts push JSON to the relay — a seam so tests never touch a network.
  /// Null means the real HTTP poster.
  final PushPost? _pushPost;

  /// Sealed, best-effort push fan-out for devices with no live link. Each
  /// push POSTs to the device's OWN relay — never to one it cannot hear.
  late final PushFanout _pushFanout = PushFanout(
    devices: devices.getActive,
    // A phone that is connected but not looking is not shown the live
    // stream, so for news it counts as not hearing it.
    hasLiveLink: isWatching,
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
      final fallback = relay;
      if (fallback != null) urls[fallback.toString()] = fallback;
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
    final host = _localRelayUrl?.host ?? lanHost;
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
        runtime.push((api) => api.sendHostStatus()),
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

  /// Serves a desktop client whose sealed channel switched to the host
  /// protocol (slice 5e). Null refuses every `host.attach`.
  void Function(SealedHostLink link)? onHostLink;
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
      _lanServer = await LanTransportServer.bind(
        address: lanAddress,
        port: lanPort,
        onLog: onLog,
      );
    } on SocketException {
      // The preferred port is taken; any port works — the beacon carries it.
      _lanServer = await LanTransportServer.bind(
        address: lanAddress,
        port: 0,
        onLog: onLog,
      );
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
  ///
  /// With no [relay] and no configured one the pairing is **direct**: the
  /// phone dials this machine's LAN listener, nothing waits at any relay, and
  /// the row names none — so no relay is ever dialled for that phone.
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
    final fallback = this.relay;
    final payload = await PairingPayload.generateWithCode(
      // The payload carries a relay either way; a direct pairing names nowhere.
      relay: pairingRelay ?? Uri.parse('https://invalid.local'),
      hostId: hostId,
      capabilities: capabilities,
      // The tab's relay stays the payload's `relay` — an older companion reads
      // that alone — while the QR names every other relay this host serves.
      relays: [
        ?_localRelayUrl,
        ..._extraRelays,
        if (_hostedEnabled && fallback != null) fallback,
      ],
    );
    final session = HostPairingSession(
      payload: payload,
      hostName: bindings.hostName,
      now: _now,
      persist: (device) async {
        final stamped = device.copyWith(
          relayUrl: relayIsLocal ? kLocalRelayMarker : pairingRelay?.toString(),
        );
        devices.insert(stamped);
        onDevicesChanged?.call();
        await _rebuildRuntime(stamped);
      },
    );
    _pairing = session;
    if (pairingRelay != null) {
      final transport = _relayFactory(pairingRelay, payload.rendezvous);
      _pairingTransport = transport;
      session.attach(transport);
    }
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

  /// Changes what [deviceId] may do, **without touching its key or its link**:
  /// the row is written, the live runtime is told, and the phone hears its new
  /// grant on a fresh `host.status`. Enforcement is per frame, so the next one
  /// is already judged by this set. A switched link (a desktop or phone
  /// client) is retired instead, and reattaches with the new grant.
  Future<void> updateCapabilities(
    String deviceId,
    CapabilitySet capabilities,
  ) async {
    devices.updateCapabilities(deviceId, capabilities);
    final updated = devices.getById(deviceId);
    onDevicesChanged?.call();
    if (updated == null || updated.revoked) return;
    await _runtimes[deviceId]?.applyGrant(updated);
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

  /// Brings every live runtime in line with rows another process changed — a
  /// grant edited, a phone revoked or re-paired in the desktop's settings while
  /// this process serves it. A revoked row is told, then torn down, exactly as
  /// [revoke] does it; a changed grant is applied on the link it holds.
  Future<void> reconcileDevices() async {
    if (!_started) return;
    final rows = {for (final row in devices.getAll()) row.id: row};
    for (final entry in _runtimes.entries.toList()) {
      final row = rows[entry.key];
      final runtime = entry.value;
      final gone =
          row == null ||
          row.revoked ||
          row.deviceKey.isEmpty ||
          !_sameKey(row.deviceKey, runtime.device.deviceKey);
      if (gone) {
        _runtimes.remove(entry.key);
        if (row == null || row.revoked || row.deviceKey.isEmpty) {
          try {
            await runtime.run((api) => api.sendPairingRevoked());
          } on Object catch (error) {
            onLog?.call('could not tell the device it was revoked: $error');
          }
        }
        await runtime.close();
        _lanRoutes.removeWhere((_, route) => route.deviceId == entry.key);
        continue;
      }
      if (row.capabilities.bits != runtime.device.capabilities.bits) {
        await runtime.applyGrant(row);
      }
    }
    for (final row in rows.values) {
      await _ensureRuntime(row);
    }
  }

  static bool _sameKey(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
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
  /// about it. A device with no live link hears it as a sealed push instead —
  /// see [pushAttentionNews] — so nothing is written into a dead one.
  Future<void> notifyApprovalRequested(String sessionId) async {
    await Future.wait([
      for (final runtime in _runtimes.values.toList())
        runtime.push((api) => api.pushApprovalRequested(sessionId)),
    ]);
  }

  /// Whether [deviceId]'s phone can hear events right now: a frame arrived on
  /// its active link since the carrying transport last dropped.
  bool hasLiveLink(String deviceId) => _runtimes[deviceId]?.peerLive ?? false;

  /// Whether [deviceId]'s phone is connected **and** in front of its owner —
  /// the one that earns the live stream. A phone that never said is watching
  /// while connected, as every phone was before it could say.
  bool isWatching(String deviceId) => _runtimes[deviceId]?.watching ?? false;

  /// Whether [deviceId] is parked: its relays are off, so only a direct LAN
  /// link reaches it. It resumes when one returns — no re-pair.
  bool isParked(String deviceId) => _runtimes[deviceId]?.parked ?? false;

  /// Attention news for phones with no live link, sealed per device and posted
  /// to their relay; a connected phone hears `session.changed`. Never throws.
  Future<void> pushAttentionNews({
    required String sessionId,
    required String title,
    required String kind,
    String? detail,
  }) async {
    if (!_started) return;
    try {
      await _pushFanout.notifyAttention(
        sessionId: sessionId,
        title: title,
        kind: kind,
        detail: detail,
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
