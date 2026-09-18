/// The real protocol client behind the [CompanionGateway] seam: one adapter,
/// no protocol logic of its own, adding the contract the phone UI pinned —
/// streams that seed their current value, refusals worded for a reader.
///
/// Each family lives in a `part` beside this file. The surface itself cannot
/// move out: an extension member does not satisfy `implements`.
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:io';

import '../../domain/companion_presence.dart';
import '../../client/companion_client.dart';
import '../../client/companion_pairing_client.dart';
import '../../client/companion_store.dart' as stored;
import '../../client/lan_path.dart';
import '../../client/relay_candidates.dart';
import '../../domain/remote_payloads.dart';
import '../../pairing/companion_device_name.dart';
import '../../pairing/host_pairing_invite.dart';
import '../../pairing/pairing_code.dart';
import '../../pairing/pairing_payload.dart';
import '../../protocol.dart';
import '../../transport/key_schedule.dart';
import '../../transport/lan_beacon.dart';
import '../../transport/lan_transport.dart';
import '../../transport/relay_transport.dart';
import '../../transport/remote_transport.dart';
import 'companion_gateway.dart';
import 'route_labels.dart';

part 'remote_companion_gateway_state.dart';
part 'remote_companion_gateway_refusals.dart';
part 'remote_companion_gateway_pairing.dart';
part 'remote_companion_gateway_connections.dart';
part 'remote_companion_gateway_connect_loop.dart';
part 'remote_companion_gateway_dial.dart';
part 'remote_companion_gateway_promotion.dart';
part 'remote_companion_gateway_liveness.dart';
part 'remote_companion_gateway_notifications.dart';
part 'remote_companion_gateway_sessions.dart';
part 'remote_companion_gateway_transcript.dart';
part 'remote_companion_gateway_host_events.dart';
part 'remote_companion_gateway_approvals.dart';
part 'remote_companion_gateway_attachments.dart';

/// The real gateway: [CompanionClient] + [CompanionPairingClient] over an
/// injected [stored.CompanionStore] (`SecureCompanionStore` on a phone).
class RemoteCompanionGateway implements CompanionGateway {
  RemoteCompanionGateway({
    required this.store,
    this.deviceModel,
    this.deviceKind = CompanionDeviceKind.unknown,
    RelayTransportFactoryFn? relayFactory,
    this.requestTimeout = const Duration(seconds: 15),
    this.helloTimeout = const Duration(seconds: 8),
    this.linkHealGrace = const Duration(seconds: 10),
    this.pairingTimeout = const Duration(seconds: 20),
    this.lan,
    LanDialerFn? directDialer,
    this.pushTokenSource,
    Backoff? reconnectBackoff,
    Backoff? localReconnectBackoff,
    DateTime Function()? now,
    this.onLog,
  }) : _directDialer = directDialer ?? _defaultDirectDialer,
       _relayFactory = relayFactory ?? _defaultRelayFactory,
       _backoff = reconnectBackoff ?? Backoff(),
       _localBackoff =
           localReconnectBackoff ??
           Backoff(
             initial: const Duration(milliseconds: 200),
             maximum: const Duration(seconds: 2),
           ),
       _now = now ?? DateTime.now {
    _ready = _loadStoredPairing();
  }

  /// A plain TCP dial. `host` may be a name — the transport resolves it — which
  /// is why the direct path does not go through `DiscoveredHost`.
  static RemoteTransport _defaultDirectDialer(String host, int port) =>
      LanTransport(host: host, port: port)..start();

  static RemoteTransport _defaultRelayFactory(
    Uri relay,
    RendezvousId rendezvous,
  ) => RelayTransport.connect(relay: relay, rendezvous: rendezvous);

  /// Where the pairing record lives — `SecureCompanionStore` on a real phone,
  /// a map-backed fake in tests.
  final stored.CompanionStore store;

  /// What the desktop's device list will call this phone.
  /// What this device says it is, or null when it could not be read. The name
  /// on the wire is built from it and the stable device id, so two phones are
  /// never indistinguishable in the desktop's list.
  final String? deviceModel;

  /// What this companion runs on, as `notifications.register` reports it.
  /// [CompanionDeviceKind.unknown] by default: a build not told must not guess.
  final CompanionDeviceKind deviceKind;

  final Duration requestTimeout;
  final Duration helloTimeout;

  /// How long a transport that dropped is left to redial its own endpoint
  /// before the gateway stops waiting and dials every saved path again.
  final Duration linkHealGrace;

  /// The window one pairing attempt gets before both legs — LAN and relay —
  /// are declared failed together.
  final Duration pairingTimeout;

  /// The LAN leg — beacon listening and direct dialling (design §3: direct
  /// first, relay fallback). Null keeps the gateway relay-only.
  final LanPathScout? lan;

  /// Where a push token comes from once Loop D wires FCM. Null — or a null
  /// answer — skips `notifications.register` gracefully.
  final Future<({String token, String platform})?> Function()? pushTokenSource;

  /// Lifecycle only — never called with payload content.
  final void Function(String message)? onLog;

  final RelayTransportFactoryFn _relayFactory;

  /// How the direct path reaches a peer with an address of its own. A seam, so
  /// a test can dial a fake instead of a socket.
  final LanDialerFn _directDialer;

  /// Waits between full re-dials. Blips inside a connection are the
  /// transport's own backoff, not this one.
  final Backoff _backoff;

  /// The same, for a desktop on this network. A schedule that climbs to half a
  /// minute is the wrong answer for a machine on the same table.
  final Backoff _localBackoff;

  /// Whether the connection that just ended ran over something local, which
  /// decides which schedule the next wait comes from.
  bool _lastPathWasLocal = false;

  final DateTime Function() _now;

  late final Future<void> _ready;

  /// Every saved desktop, and which is active. The active record is mirrored
  /// in [_record] because everything below reads one host at a time.
  stored.CompanionConnections _all = stored.CompanionConnections();

  stored.CompanionPairing? _record;
  CompanionClient? _client;
  StreamSubscription<CompanionEvent>? _clientEvents;
  RemoteTransport? _dialled;
  StreamSubscription<TransportState>? _transportStates;

  final _pairing = _Watched<CompanionPairing?>(null);
  final _connections = _Watched<List<CompanionConnection>>(const []);
  late final _link = _Watched<CompanionLinkState>(
    CompanionLinkState.disconnected,
    onSet: _stampLink,
  );
  final _linkPath = _Watched<CompanionLinkPath?>(null);

  /// When [_link] last changed, for the age every reading owes (§19).
  final _linkSince = _Watched<DateTime?>(null);

  /// The state [_linkSince] was written for. A transport reports the state it
  /// is IN, so a redial reports `connecting` over and over; a stamp that moved
  /// on every report would call an hour-old outage fresh.
  CompanionLinkState? _stampedLink;

  void _stampLink() {
    if (_link.value == _stampedLink) return;
    _stampedLink = _link.value;
    _linkSince.value = _now().toUtc();
  }

  final _progress = StreamController<CompanionPairingProgress>.broadcast(
    sync: true,
  );
  final _sessionChanges =
      StreamController<List<CompanionSessionSummary>>.broadcast(sync: true);
  final _attention = StreamController<CompanionAttentionEvent>.broadcast(
    sync: true,
  );

  List<CompanionSessionSummary>? _sessions;

  /// The session ids in the order the host last listed them.
  final _hostOrder = <String>[];

  final _subscribed = <String>{};
  final _lastAttention = <String, String?>{};
  final _transcripts = <String, _TranscriptState>{};
  final _approvals = <String, _Watched<CompanionApproval?>>{};

  /// What each session was last heard to be doing. Seeded unknown, because a
  /// phone that has heard nothing has not heard "nothing".
  final _activity = <String, _Watched<CompanionActivity>>{};
  final _approvalResolutions =
      StreamController<CompanionApprovalResolution>.broadcast();
  int _nextApprovalId = 1;

  bool _loopRunning = false;
  bool _closed = false;

  /// Set while a deliberate host switch tears the old link down, so the loop
  /// dials the new desktop instead of backing off from the drop.
  bool _switching = false;
  Completer<void>? _died;

  /// A death declared while the loop was between two of its own awaits, with no
  /// [_died] in existence to complete. Thrown away, it parked the loop on a
  /// completer nothing would finish and the phone on "Connecting…".
  bool _deathPending = false;

  /// Set when the pass in flight has been overtaken by a retry, a pairing or a
  /// switch. Distinct from [_deathPending]: a request that found the link down
  /// is news about the link, not a reason to abandon the dial fixing it.
  bool _dialOvertaken = false;
  Completer<void>? _backoffWaiter;
  Future<void>? _refreshing;

  /// A LAN transport this gateway dialled itself — the client never owns a
  /// supplied transport, so teardown here must close it.
  RemoteTransport? _ownedTransport;

  /// The relay carrying the link right now, or null on the LAN path and while
  /// nothing is connected. Stamped as the last-known-good once the link is up.
  Uri? _activeRelay;

  /// The newest `host.status` this link carried, applied to the saved
  /// candidates once the connection has settled.
  RemoteHostStatus? _lastHostStatus;

  /// Serialises overlapping re-proofs: a socket that flaps twice must not
  /// leave an older, slower handshake deciding the link's fate.
  int _reproveAttempt = 0;

  /// The plainest true sentence about why the link is down, when there is one.
  /// Watched, because it changes without the link state changing with it.
  final _trouble = _Watched<String?>(null);
  bool _lanStarted = false;
  StreamSubscription<DiscoveredHost>? _lanSightings;

  /// Runs while a dropped transport is being given its chance to come back.
  Timer? _healTimer;

  /// Beacons still to be heard before the LAN is probed again, and how many the
  /// next failed promotion will ask for. Counted in beacons, never timed: a
  /// phone whose desktop stopped beaconing stops re-probing for it.
  int _promotionHoldOff = 0;
  int _promotionPenalty = 0;

  /// True while a second link is being dialled and adopted. Guards against two
  /// promotions at once, and tells the liveness watch that a drop on the link
  /// being replaced is this promotion's own doing.
  bool _promoting = false;

  /// A drop on the link being replaced, held while a promotion decides. See
  /// `_releaseDeferredDrop`.
  bool _dropDeferred = false;

  /// What this phone last said about itself, resent whenever it changes. Held
  /// rather than derived so a report made while the link is down is not lost.
  CompanionPresence _presence = CompanionPresence.unknown;

  /// Sessions with a gap recovery in flight, so two never race each other.
  final _draining = <String>{};

  /// Requests that have gone unanswered with nothing answered between them.
  int _unanswered = 0;

  /// Set when the host says the pairing is gone. Never cleared: the device key
  /// went with it, so this link cannot come back — only a fresh pairing can.
  bool _revoked = false;

  // ---------------------------------------------------------------- pairing

  @override
  CompanionPairing? get pairing => _pairing.value;

  @override
  Stream<CompanionPairing?> get pairingStates => _pairing.stream;

  @override
  CompanionLinkState get link => _link.value;

  @override
  String? get linkTrouble =>
      _link.value == CompanionLinkState.connected ? null : _trouble.value;

  @override
  Stream<String?> get linkTroubleStates => _trouble.stream;

  @override
  Stream<CompanionLinkState> get linkStates => _link.stream;

  @override
  CompanionLinkPath? get linkPath => _linkPath.value;

  @override
  Stream<CompanionLinkPath?> get linkPathStates => _linkPath.stream;

  @override
  DateTime? get linkSince => _linkSince.value;

  @override
  Stream<DateTime?> get linkSinceStates => _linkSince.stream;

  @override
  Uri? get activeRelay =>
      _linkPath.value == CompanionLinkPath.relay ? _activeRelay : null;

  @override
  CapabilitySet get capabilities => _record?.capabilities ?? CapabilitySet.none;

  @override
  Future<CompanionPairing> pairWithQr(String qrPayload) async {
    await _ready;
    if (HostPairingInvite.looksLike(qrPayload)) {
      return _pairWithInvite(qrPayload);
    }
    final PairingPayload payload;
    try {
      payload = PairingPayload.decode(qrPayload.trim());
    } on ProtocolException {
      throw _refusedPairingInput();
    } on ArgumentError {
      throw _refusedPairingInput();
    }
    _emitPairing(CompanionPairingStage.codeAccepted);
    // Pairing ADDS a desktop and switches to it, so the old host's link goes
    // first — its sessions must not bleed into the new one.
    await _dropLink();
    final pairingClient = CompanionPairingClient(
      store: store,
      deviceId: await stableDeviceId(),
      deviceName: await _deviceName(),
    );
    final record = await _runPairing(
      attempt: (link) => pairingClient.pair(
        payload,
        transport: link,
        timeout: pairingTimeout,
        onConfirm: _onPairingConfirm,
      ),
      relay: payload.relay,
      rendezvous: payload.rendezvous,
    );
    return _adoptPairing(record);
  }

  /// A session host's invite: the typed-code ceremony over the ONE route the
  /// desktop that showed it chose. The other legs are not raced behind it — the
  /// code-derived rendezvous would show the attempt to a relay nobody picked.
  Future<CompanionPairing> _pairWithInvite(String text) async {
    final HostPairingInvite invite;
    try {
      invite = HostPairingInvite.decode(text, now: _now());
    } on HostInviteExpiredException catch (error) {
      _emitPairing(CompanionPairingStage.failed, message: error.message);
      throw PairingException(error.message);
    } on HostInviteTooNewException {
      const message =
          'This code was made by a newer Karmashala. Update this app, then '
          'scan it again.';
      _emitPairing(CompanionPairingStage.failed, message: message);
      throw const PairingException(message);
    } on ProtocolException {
      throw _refusedPairingInput();
    }
    final codeSecret = PairingCode.tryDecode(invite.code)!;
    _emitPairing(CompanionPairingStage.codeAccepted);
    await _dropLink();
    final direct = invite.route == HostRoute.direct;
    // Only ever dialled on the relay route; on the direct one it is just what
    // the record has to name, and the dial never reads it.
    final relay = invite.relay ?? await pairingRelay();
    final rendezvous = await derivePairingRendezvous(
      (await derivePairingSecret(codeSecret)).bytes,
    );
    final pairingClient = CompanionPairingClient(
      store: store,
      deviceId: await stableDeviceId(),
      deviceName: await _deviceName(),
    );
    final record = await _runPairing(
      attempt: (link) => pairingClient.pairWithTypedCode(
        codeSecret: codeSecret,
        relay: relay,
        transport: link,
        timeout: pairingTimeout,
        onConfirm: _onPairingConfirm,
      ),
      relay: relay,
      rendezvous: rendezvous,
      at: direct ? invite.endpoint : null,
      legs: {direct ? _PairingLeg.direct : _PairingLeg.relay},
    );
    return _adoptPairing(
      direct
          ? record.copyWith(
              directEndpoint: invite.endpoint,
              route: HostRoute.direct,
            )
          : record.copyWith(route: HostRoute.relay),
    );
  }

  /// The typed path: a grouped base32 code carrying only the secret, or a
  /// pasted full payload — sniffed apart here. Full entropy (160 bits), so no
  /// PAKE is needed; SPAKE2 stays descoped for want of a vetted Dart one.
  @override
  Future<CompanionPairing> pairWithCode(String shortCode, {String? at}) async {
    await _ready;
    final text = shortCode.trim();
    if (text.startsWith('{')) return pairWithQr(text);
    final codeSecret = PairingCode.tryDecode(text);
    if (codeSecret == null) throw _refusedPairingInput();
    _emitPairing(CompanionPairingStage.codeAccepted);
    await _dropLink();
    final relay = await pairingRelay();
    // The code names no rendezvous; both ends derive it from the secret.
    final rendezvous = await derivePairingRendezvous(
      (await derivePairingSecret(codeSecret)).bytes,
    );
    final pairingClient = CompanionPairingClient(
      store: store,
      deviceId: await stableDeviceId(),
      deviceName: await _deviceName(),
    );
    final record = await _runPairing(
      attempt: (link) => pairingClient.pairWithTypedCode(
        codeSecret: codeSecret,
        relay: relay,
        transport: link,
        timeout: pairingTimeout,
        onConfirm: _onPairingConfirm,
      ),
      relay: relay,
      rendezvous: rendezvous,
      at: at,
    );
    // Remembered on the record, so every later dial goes straight back rather
    // than searching a network the box was never on.
    return _adoptPairing(
      at == null ? record : record.copyWith(directEndpoint: at),
    );
  }

  @override
  Stream<CompanionPairingProgress> get pairingProgress => _progress.stream;

  /// Where the typed code's relay setting lives in the phone's store.
  static const String kPairingRelayStoreKey = 'karmashala.companion.relay';

  /// Where this phone's own identity lives — beside the pairing records
  /// rather than inside one, because it must outlive unpairing every host.
  static const String kDeviceIdStoreKey = 'karmashala.remote.device_id';

  /// This phone's device id: minted once, then used by every pairing it makes.
  /// A fresh id per pairing is what made the desktop list the same phone again
  /// and again. Read at most once: two pairings racing must not mint two.
  Future<DeviceId> stableDeviceId() => _deviceIdOnce ??= _readOrMintDeviceId();
  Future<DeviceId>? _deviceIdOnce;

  Future<String> _deviceName() async => companionDeviceName(
    model: deviceModel,
    deviceId: (await stableDeviceId()).value,
  );

  @override
  Future<Uri> pairingRelay() async {
    try {
      final raw = await store.read(kPairingRelayStoreKey);
      if (raw != null) {
        final parsed = Uri.tryParse(raw.trim());
        if (parsed != null && parsed.hasScheme) return parsed;
      }
    } on Object catch (error) {
      onLog?.call('pairing relay read failed: $error');
    }
    return Uri.parse(kDefaultCompanionRelayUrl);
  }

  @override
  Future<void> setPairingRelay(Uri? url) async {
    try {
      if (url == null) {
        await store.delete(kPairingRelayStoreKey);
      } else {
        await store.write(kPairingRelayStoreKey, url.toString());
      }
    } on Object catch (error) {
      onLog?.call('saving the pairing relay failed: $error');
      throw const GatewayException(
        "This phone could not save that relay to its secure storage, so the "
        'setting is unchanged. Try again.',
      );
    }
  }

  // ------------------------------------------------------------ connections

  @override
  List<CompanionConnection> get connections => _connections.value;

  @override
  Stream<List<CompanionConnection>> get connectionsStates =>
      _connections.stream;

  @override
  Future<void> switchTo(String hostId) async {
    await _ready;
    if (_closed) return;
    if (_all.activeHostId?.value == hostId && _record != null) return;
    final target = _all.byHost(hostId);
    if (target == null) {
      throw const GatewayException(
        'That desktop is no longer saved on this phone.',
      );
    }
    try {
      _all = await stored.CompanionConnections.mutate(store, (all) {
        if (all.byHost(hostId) != null) {
          all.activeHostId = all.byHost(hostId)!.hostId;
        }
        return all;
      });
    } on Object catch (error) {
      // The keystore can refuse, and since it gained a deadline it can also
      // give up; an escaping `TimeoutException` makes the tap look inert.
      onLog?.call('switchTo failed: $error');
      throw const GatewayException(
        "This phone could not record which desktop to use, so it stayed on "
        'the one it was on. Try again.',
      );
    }
    await _becomeActive(_all.active ?? target);
  }

  @override
  Future<void> setRoutePin(String hostId, CompanionRoutePin pin) async {
    await _ready;
    if (_closed) return;
    final target = _all.byHost(hostId);
    if (target == null) {
      throw const GatewayException(
        'That desktop is no longer saved on this phone.',
      );
    }
    if (target.route != null) {
      throw const GatewayException(
        'A machine paired directly keeps the route it was paired over. To '
        'change it, pair it again from the desktop.',
      );
    }
    if (target.pin == pin) return;
    try {
      _all = await stored.CompanionConnections.mutate(store, (all) {
        final saved = all.byHost(hostId);
        if (saved != null) all.upsert(saved.withPin(pin));
        return all;
      });
    } on Object catch (error) {
      onLog?.call('setRoutePin failed: $error');
      throw const GatewayException(
        'This phone could not save the route, so it kept the one it had. '
        'Try again.',
      );
    }
    if (_all.activeHostId?.value != hostId || _record == null) {
      // A background desktop: its next dial reads the pin from the record.
      _publishConnections();
      return;
    }
    // The in-memory record, not the stored one: the client persists its own
    // generation bump, and this must not walk it back.
    _record = _record!.withPin(pin);
    _publishConnections();
    // What the last route said about itself is not a statement about this one.
    _noteTrouble(null);
    // Re-dialled at once, as a switch is — but the same desktop, so nothing it
    // holds is cleared: a teardown marks open transcripts stale, and the next
    // link re-reads them from their cursors.
    _switching = true;
    _link.value = CompanionLinkState.connecting;
    await _dropLink(keepState: true);
    _resetBackoff();
    _startLoop();
  }

  @override
  Future<void> removeConnection(String hostId) async {
    await _ready;
    if (_all.byHost(hostId) == null) return;
    final wasActive = _all.activeHostId?.value == hostId;
    try {
      _all = await stored.CompanionConnections.mutate(store, (all) {
        all.remove(hostId);
        return all;
      });
    } on Object catch (error) {
      onLog?.call('removeConnection failed: $error');
      throw const GatewayException(
        "That desktop could not be removed from this phone's secure storage. "
        'Try again.',
      );
    }
    if (!wasActive) {
      // A background record went away; the live link is untouched.
      _publishConnections();
      return;
    }
    // The active one went: fall back to whatever the store chose, or unpaired.
    await _becomeActive(_all.active);
  }

  @override
  Future<void> unpair() async {
    await _ready;
    final active = _record;
    if (active == null) return;
    // Multi-host: unpairing forgets the ACTIVE desktop and falls back to
    // another saved one, or to unpaired when it was the last.
    await removeConnection(active.hostId.value);
  }

  @override
  Future<void> reconnect() async {
    await _ready;
    if (_closed || _record == null) return;
    // **The schedule, not just the wait in front of it.** Every caller is a
    // reason to believe the world changed, and a schedule that kept its attempt
    // count answered the very next failure with sixteen seconds.
    _resetBackoff();
    final waiter = _backoffWaiter;
    if (waiter != null && !waiter.isCompleted) {
      // Skip the wait; the loop dials immediately.
      waiter.complete();
      return;
    }
    if (!_loopRunning) {
      _startLoop();
      return;
    }
    // Mid-cycle: a link that does not look healthy is torn down and re-dialled,
    // including one still dialling, rather than making the user wait it out.
    if (_link.value != CompanionLinkState.connected) {
      _dialOvertaken = true;
      _declareDead();
      return;
    }
    // After a resume, "up" is a claim about a socket nobody watched while the
    // app was frozen, so it is proved rather than taken: one hello, one
    // `host.status`, and silence declares it dead.
    unawaited(_reproveLink());
  }

  // --------------------------------------------------------------- sessions

  @override
  Future<List<CompanionSessionSummary>> listSessions() async {
    await _ready;
    final client = _requireClient();
    final rows = await _mapRefusals(client.listSessionRows);
    for (final row in rows) {
      // Seed the attention baseline silently: notifications are for news
      // that happens while we watch, not the state we walked in on.
      _lastAttention.putIfAbsent(
        row.snapshot.sessionId,
        () => row.snapshot.attention,
      );
    }
    // The host's order IS the order — the phone re-sorting it is what made the
    // list jump. Archived rows are kept and labelled rather than dropped.
    final list = [
      for (final row in rows) _summaryOf(row.snapshot, raw: row.json),
    ];
    _hostOrder
      ..clear()
      ..addAll([for (final row in rows) row.snapshot.sessionId]);
    _setSessions(list);
    return list;
  }

  @override
  Stream<List<CompanionSessionSummary>> watchSessions() =>
      Stream.multi((controller) {
        final subscription = _sessionChanges.stream.listen(controller.add);
        controller.onCancel = subscription.cancel;
        unawaited(() async {
          await _ready;
          final cached = _sessions;
          if (cached != null) {
            controller.add(cached);
          } else if (_record == null) {
            controller.add(const []);
          }
          unawaited(_refreshSessions());
        }());
      });

  @override
  Stream<List<CompanionChatMessage>> transcript(String sessionId) =>
      Stream.multi((controller) {
        final state = _transcriptOf(sessionId);
        state.listeners.add(controller);
        controller.onCancel = () {
          state.listeners.remove(controller);
          // Deliberately no session.unsubscribe: the list keeps every session
          // subscribed anyway, and a redial rebuilds them from scratch.
        };
        unawaited(_primeTranscript(sessionId, controller));
      });

  @override
  Stream<CompanionApproval?> pendingApproval(String sessionId) =>
      _approvalOf(sessionId).stream;

  @override
  Stream<CompanionActivity> activity(String sessionId) => Stream.multi((
    controller,
  ) {
    final watched = _activityOf(sessionId);
    final subscription = watched.stream.listen(controller.add);
    controller.onCancel = subscription.cancel;
    // Asked outright once, because the host states this unprompted and an
    // unprompted frame cannot be replayed for a screen that opened after it.
    unawaited(_primeActivity(sessionId));
  });

  @override
  Future<List<RemoteWorkspaceProject>> listWorkspace() async {
    await _ready;
    final client = _requireClient();
    final result = await _mapRefusals(client.listWorkspace);
    _ensureCurrentClient(client);
    return result;
  }

  @override
  Future<List<RemoteWorkspaceProject>> listProjects() async {
    await _ready;
    final client = _requireClient();
    final result = await _mapRefusals(client.listProjects);
    _ensureCurrentClient(client);
    return result;
  }

  @override
  Future<RemoteWorkspaceProject> addProject({
    required String requestId,
    required String name,
    required String path,
  }) async {
    await _ready;
    final client = _requireClient();
    final project = await _mapRefusals(
      () => client.addProject(requestId: requestId, name: name, path: path),
    );
    _ensureCurrentClient(client);
    await _refreshSessionsNow();
    return project;
  }

  @override
  Future<RemoteSessionStarted> startSession({
    required String requestId,
    required String repositoryId,
    required String installationId,
    required String permissionMode,
    String? title,
    String? message,
  }) async {
    await _ready;
    final client = _requireClient();
    final started = await _mapRefusals(
      () => client.startSession(
        requestId: requestId,
        repositoryId: repositoryId,
        installationId: installationId,
        permissionMode: permissionMode,
        title: title,
        message: message,
      ),
    );
    _ensureCurrentClient(client);
    // Relist before answering, so the screen the caller pushes next finds the
    // new session's row and its transcript subscription already there.
    await _refreshSessionsNow();
    return started;
  }

  @override
  Future<RemoteSessionStarted> resumeSession({
    required String requestId,
    required String sessionId,
  }) async {
    await _ready;
    final client = _requireClient();
    final resumed = await _mapRefusals(
      () => client.resumeSession(requestId: requestId, sessionId: sessionId),
    );
    _ensureCurrentClient(client);
    await _refreshSessionsNow();
    return resumed;
  }

  @override
  Future<RemotePromptDelivery> sendPrompt(
    String sessionId,
    String text, {
    CompanionOutgoingAttachment? attachment,
    void Function(int sent, int total)? onProgress,
    String? requestId,
  }) async {
    await _ready;
    final client = _requireClient();
    if (attachment == null) {
      return _mapRefusals(
        () => client.sendPrompt(sessionId, text, requestId: requestId),
      );
    }
    final uploadId = await _uploadAttachment(
      client,
      sessionId,
      attachment,
      onProgress,
    );
    // The prompt is the commit: the host checks the length here, so a short
    // upload takes the prompt with it rather than becoming a truncated file.
    return _mapRefusals(
      () => client.sendPrompt(
        sessionId,
        text,
        attachmentId: uploadId,
        requestId: requestId,
      ),
    );
  }

  @override
  Future<void> answerApproval(
    String sessionId,
    String approvalId,
    CompanionApprovalDecision decision,
  ) async {
    await _ready;
    final client = _requireClient();
    await _mapRefusals(
      () => client.answerApproval(
        sessionId,
        approve: decision == CompanionApprovalDecision.approve,
        approvalId: approvalId,
      ),
    );
    final pending = _approvalOf(sessionId);
    if (pending.value?.id == approvalId) pending.value = null;
  }

  @override
  Stream<CompanionApprovalResolution> get approvalResolutions =>
      _approvalResolutions.stream;

  @override
  Stream<CompanionAttentionEvent> get attentionEvents => _attention.stream;

  @override
  Future<void> reportVisibility(CompanionVisibility visibility) =>
      _report(_presence.copyWith(visibility: visibility));

  @override
  Future<void> reportFocusedSession(String? sessionId) => _report(
    _presence.copyWith(
      focusedSessionId: sessionId,
      clearFocusedSession: sessionId == null,
    ),
  );

  /// Stops everything. For tests and the provider container's dispose — a
  /// phone unpairs, it never closes its gateway.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _declareDead();
    final waiter = _backoffWaiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    await _lanSightings?.cancel();
    _lanSightings = null;
    await _teardownClient();
    final scout = lan;
    if (scout != null && _lanStarted) {
      try {
        await scout.stop();
      } on Object catch (error) {
        onLog?.call('lan scout stop failed: $error');
      }
    }
    _link.value = CompanionLinkState.disconnected;
    await _sessionChanges.close();
    await _attention.close();
    await _approvalResolutions.close();
    await _progress.close();
  }
}
