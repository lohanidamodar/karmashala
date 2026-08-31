/// Loop 70's real protocol client behind Loop 71's [CompanionGateway] seam.
///
/// One adapter, no protocol logic of its own: pairing runs through
/// [CompanionPairingClient], the session API through [CompanionClient], and
/// reconnection through the transports' own backoff. What this file adds is
/// the contract the phone UI pinned: streams that seed their current value,
/// and every refusal rewritten as a sentence a user can read.
library;

import 'dart:async';
import 'dart:io';

import '../../remote/client/companion_client.dart';
import '../../remote/client/companion_pairing_client.dart';
import '../../remote/client/companion_store.dart' as stored;
import '../../remote/client/lan_path.dart';
import '../../remote/client/relay_candidates.dart';
import '../../remote/domain/remote_payloads.dart';
import '../../remote/pairing/pairing_code.dart';
import '../../remote/pairing/pairing_payload.dart';
import '../../remote/protocol.dart';
import '../../remote/transport/key_schedule.dart';
import '../../remote/transport/lan_beacon.dart';
import '../../remote/transport/relay_transport.dart';
import '../../remote/transport/remote_transport.dart';
import 'companion_gateway.dart';

/// The two refusals every unreachable-or-unpaired path shares; kept identical
/// to the fake gateway's copy so the UI reads one voice.
const String _kNotPaired = 'This phone is not paired with a host.';
const String _kUnreachable =
    'The host is unreachable right now, so nothing was sent.';

/// A current value plus its changes. Streams emit the value on listen, then
/// every set — the seeding the gateway contract asks for.
class _Watched<T> {
  _Watched(this._value);

  T _value;
  final _changes = StreamController<T>.broadcast(sync: true);

  T get value => _value;

  set value(T next) {
    _value = next;
    _changes.add(next);
  }

  Stream<T> get stream async* {
    yield _value;
    yield* _changes.stream;
  }
}

/// One session's transcript as this phone has assembled it so far.
class _TranscriptState {
  final listeners = <MultiStreamController<List<CompanionChatMessage>>>{};
  List<CompanionChatMessage> messages = const [];
  int cursor = 0;
  bool loaded = false;

  /// True once a re-dial invalidated [cursor]: what is held still shows, but
  /// appends must wait for a full re-read.
  bool stale = false;
}

/// The real gateway: [CompanionClient] + [CompanionPairingClient] over an
/// injected [stored.CompanionStore] (`SecureCompanionStore` on a phone).
class RemoteCompanionGateway implements CompanionGateway {
  RemoteCompanionGateway({
    required this.store,
    this.deviceName = 'Companion',
    RelayTransportFactoryFn? relayFactory,
    this.requestTimeout = const Duration(seconds: 15),
    this.helloTimeout = const Duration(seconds: 8),
    this.pairingTimeout = const Duration(seconds: 20),
    this.lan,
    this.pushTokenSource,
    Backoff? reconnectBackoff,
    DateTime Function()? now,
    this.onLog,
  }) : _relayFactory = relayFactory ?? _defaultRelayFactory,
       _backoff = reconnectBackoff ?? Backoff(),
       _now = now ?? DateTime.now {
    _ready = _loadStoredPairing();
  }

  static RemoteTransport _defaultRelayFactory(
    Uri relay,
    RendezvousId rendezvous,
  ) => RelayTransport.connect(relay: relay, rendezvous: rendezvous);

  /// Where the pairing record lives — `SecureCompanionStore` on a real phone,
  /// a map-backed fake in tests.
  final stored.CompanionStore store;

  /// What the desktop's device list will call this phone.
  final String deviceName;

  final Duration requestTimeout;
  final Duration helloTimeout;

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

  /// Waits between full re-dials. Blips inside a connection are the
  /// transport's own backoff, not this one.
  final Backoff _backoff;

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
  final _link = _Watched<CompanionLinkState>(CompanionLinkState.disconnected);
  final _linkPath = _Watched<CompanionLinkPath?>(null);
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
  int _nextApprovalId = 1;

  bool _loopRunning = false;
  bool _closed = false;

  /// Set while a deliberate host switch is tearing the old link down, so the
  /// loop dials the new desktop straight away instead of treating the drop as
  /// an outage to back off from.
  bool _switching = false;
  Completer<void>? _died;
  Completer<void>? _backoffWaiter;
  Future<void>? _refreshing;

  /// A LAN transport this gateway dialled itself — the client never owns a
  /// supplied transport, so teardown here must close it.
  RemoteTransport? _ownedTransport;

  /// The relay carrying the link right now, or null on the LAN path and while
  /// nothing is connected. Read by the settings screen, and stamped as the
  /// last-known-good once the link comes up.
  Uri? _activeRelay;

  /// The newest `host.status` this link carried, applied to the saved
  /// candidates once the connection has settled.
  RemoteHostStatus? _lastHostStatus;

  /// Serialises overlapping re-proofs: a socket that flaps twice must not
  /// leave an older, slower handshake deciding the link's fate.
  int _reproveAttempt = 0;

  /// The plainest true sentence about why the link is down, when there is one
  /// worth adding to the banner's own words.
  String? _trouble;
  bool _lanStarted = false;
  StreamSubscription<DiscoveredHost>? _lanSightings;
  Timer? _lanHealTimer;

  // ---------------------------------------------------------------- pairing

  @override
  CompanionPairing? get pairing => _pairing.value;

  @override
  Stream<CompanionPairing?> get pairingStates => _pairing.stream;

  @override
  CompanionLinkState get link => _link.value;

  @override
  String? get linkTrouble =>
      _link.value == CompanionLinkState.connected ? null : _trouble;

  @override
  Stream<CompanionLinkState> get linkStates => _link.stream;

  @override
  CompanionLinkPath? get linkPath => _linkPath.value;

  @override
  Stream<CompanionLinkPath?> get linkPathStates => _linkPath.stream;

  @override
  Uri? get activeRelay =>
      _linkPath.value == CompanionLinkPath.relay ? _activeRelay : null;

  @override
  CapabilitySet get capabilities => _record?.capabilities ?? CapabilitySet.none;

  @override
  Future<CompanionPairing> pairWithQr(String qrPayload) async {
    await _ready;
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
      deviceName: deviceName,
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

  /// The typed path: a grouped base32 code carrying only the secret, or a
  /// pasted full payload — sniffed apart here. Full entropy (160 bits), so no
  /// PAKE is needed the way a short code would; SPAKE2 remains descoped (no
  /// vetted pure-Dart implementation).
  @override
  Future<CompanionPairing> pairWithCode(String shortCode) async {
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
      deviceName: deviceName,
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
    );
    return _adoptPairing(record);
  }

  @override
  Stream<CompanionPairingProgress> get pairingProgress => _progress.stream;

  /// Where the typed code's relay setting lives in the phone's store.
  static const String kPairingRelayStoreKey = 'chitragupta.companion.relay';

  /// Where this phone's own identity lives — beside the pairing records
  /// rather than inside one, because it must outlive unpairing every host.
  static const String kDeviceIdStoreKey = 'chitragupta.remote.device_id';

  /// This phone's device id: minted once, then used by every pairing it ever
  /// makes.
  ///
  /// A fresh id per pairing is what made the desktop list the same phone
  /// again and again, each new row holding a key that would never be used
  /// again. The id is not a secret and proves nothing — the sealed handshake
  /// does that — it is only the name the desktop files this phone under, so
  /// re-pairing lands on the row that is already there.
  ///
  /// Read at most once per gateway: two pairings racing must not mint two.
  Future<DeviceId> stableDeviceId() => _deviceIdOnce ??= _readOrMintDeviceId();
  Future<DeviceId>? _deviceIdOnce;

  Future<DeviceId> _readOrMintDeviceId() async {
    try {
      final raw = await store.read(kDeviceIdStoreKey);
      if (raw != null) return DeviceId.parse(raw);
    } on Object catch (error) {
      onLog?.call('stored device id unreadable: $error');
    }
    // A phone that paired before this key existed already has an identity in
    // its active record — adopting it means the desktop sees the SAME phone
    // and refreshes its row, instead of one last duplicate.
    await _ready;
    final inherited = _all.active?.deviceId ?? _record?.deviceId;
    final id = inherited ?? DeviceId.generate();
    try {
      await store.write(kDeviceIdStoreKey, id.value);
    } on Object catch (error) {
      // Pairing still works; it is only the stability that is at risk, and
      // saying so beats a silent duplicate on the desktop next time.
      onLog?.call('could not persist this phone\'s device id: $error');
    }
    return id;
  }

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
    if (url == null) {
      await store.delete(kPairingRelayStoreKey);
    } else {
      await store.write(kPairingRelayStoreKey, url.toString());
    }
  }

  PairingException _refusedPairingInput() {
    const refusal = PairingException(
      'That is not a Chitragupta pairing code. Scan the QR from the '
      "desktop's Remote access settings, type the code shown under it, or "
      'paste its full pairing payload here.',
    );
    _emitPairing(CompanionPairingStage.failed, message: refusal.message);
    return refusal;
  }

  void _onPairingConfirm(String hostName, CapabilitySet capabilities) =>
      _emitPairing(
        CompanionPairingStage.proving,
        hostName: hostName,
        capabilities: capabilities,
      );

  void _emitPairing(
    CompanionPairingStage stage, {
    String? detail,
    String? hostName,
    CapabilitySet? capabilities,
    String? message,
  }) {
    if (_progress.isClosed) return;
    _progress.add(
      CompanionPairingProgress(
        stage: stage,
        detail: detail,
        hostName: hostName,
        capabilities: capabilities,
        message: message,
      ),
    );
  }

  /// A freshly paired host becomes a saved connection AND the active one.
  /// Pairing a host this phone already holds replaces that record alone; the
  /// pairing client has already written it, so this re-reads the set.
  Future<CompanionPairing> _adoptPairing(stored.CompanionPairing record) async {
    _all = await stored.CompanionConnections.mutate(store, (all) {
      all
        ..upsert(record)
        ..activeHostId = record.hostId;
      return all;
    });
    _record = _all.active ?? record;
    final public = _publicPairing(_record!);
    _pairing.value = public;
    _publishConnections();
    _emitPairing(
      CompanionPairingStage.paired,
      hostName: public.hostName,
      capabilities: record.capabilities,
    );
    // The old host's connect loop may have re-dialled it while the pairing
    // race ran, so tear that link down again now that the new record is the
    // active one — otherwise the phone would sit on the previous desktop
    // while claiming to be on this one.
    _switching = true;
    await _dropLink(keepState: true);
    _resetHostState();
    _link.value = CompanionLinkState.connecting;
    _backoff.reset();
    _startLoop();
    return public;
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
    _all = await stored.CompanionConnections.mutate(store, (all) {
      if (all.byHost(hostId) != null) all.activeHostId = all.byHost(hostId)!.hostId;
      return all;
    });
    await _becomeActive(_all.active ?? target);
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

  /// Drops the current link and rebuilds every derived state for [record] —
  /// or for no host at all when it is null. Nothing from the old desktop may
  /// bleed into the new one, so the session list, subscriptions, transcripts,
  /// approvals and attention baselines are all cleared before the dial.
  Future<void> _becomeActive(stored.CompanionPairing? record) async {
    _record = record;
    _pairing.value = record == null ? null : _publicPairing(record);
    _publishConnections();
    // Connecting, not disconnected: the user asked for this desktop, and a
    // "host unreachable" banner before anything was tried would be a lie.
    _switching = record != null;
    if (_switching) _link.value = CompanionLinkState.connecting;
    await _dropLink(keepState: _switching);
    _resetHostState();
    if (record == null) {
      _switching = false;
      _link.value = CompanionLinkState.disconnected;
      return;
    }
    _backoff.reset();
    _startLoop();
  }

  /// Everything the gateway holds that belongs to ONE host.
  void _resetHostState() {
    _sessions = null;
    _hostOrder.clear();
    if (!_sessionChanges.isClosed) _sessionChanges.add(const []);
    _subscribed.clear();
    _lastAttention.clear();
    for (final approval in _approvals.values) {
      approval.value = null;
    }
    _approvals.clear();
    for (final state in _transcripts.values) {
      state.loaded = false;
      state.stale = false;
      state.cursor = 0;
      state.messages = const [];
      // A screen still watching an old host's transcript must not keep
      // showing its rows against the new one.
      _pushTranscript(state);
    }
    _transcripts.removeWhere((_, state) => state.listeners.isEmpty);
  }

  /// Runs the race and rewrites every failure as a sentence, mirroring the
  /// old single-path error mapping.
  Future<stored.CompanionPairing> _runPairing({
    required Future<stored.CompanionPairing> Function(RemoteTransport link)
    attempt,
    required Uri relay,
    required RendezvousId rendezvous,
  }) async {
    try {
      return await _pairOverAnyPath(
        attempt: attempt,
        relay: relay,
        rendezvous: rendezvous,
      );
    } on PairingException catch (error) {
      _emitPairing(CompanionPairingStage.failed, message: error.message);
      rethrow;
    } on Object catch (error) {
      onLog?.call('pairing failed: $error');
      const failure = PairingException(
        'Pairing failed before the desktop could confirm it. Check the '
        'connection and scan a fresh code.',
      );
      _emitPairing(CompanionPairingStage.failed, message: failure.message);
      throw failure;
    }
  }

  /// Design §3 applied to pairing itself: every fresh LAN candidate races the
  /// relay, the first sealed round-trip wins and the loser's transport is
  /// closed under it. A dead relay must not sink pairing when the desktop is
  /// one Wi-Fi hop away — and a dark LAN must not sink it when the relay is
  /// fine. Only when BOTH legs fail does one combined sentence say which
  /// failed how.
  Future<stored.CompanionPairing> _pairOverAnyPath({
    required Future<stored.CompanionPairing> Function(RemoteTransport link)
    attempt,
    required Uri relay,
    required RendezvousId rendezvous,
  }) async {
    final scout = lan;
    _ensureLanScout();
    _emitPairing(
      CompanionPairingStage.searching,
      detail: scout == null
          ? 'over the relay'
          : 'on this network and over the relay',
    );
    final outcome = Completer<stored.CompanionPairing>();
    final open = <RemoteTransport>{};
    var cancelled = false;
    String? relayNote;
    String? lanNote;
    // A refusal with a story of its own (wrong protocol version, a desktop
    // too old for typed codes) beats the generic connectivity sentence.
    CompanionPairingException? sharp;

    bool isSharp(CompanionPairingException error) =>
        !error.message.contains('did not answer') &&
        !error.message.contains('connection closed');

    Future<void> closeTransport(RemoteTransport transport) async {
      if (!open.remove(transport)) return;
      try {
        await transport.close();
      } on Object catch (error) {
        onLog?.call('pairing transport close failed: $error');
      }
    }

    Future<void> relayLeg() async {
      final transport = _relayFactory(relay, rendezvous);
      open.add(transport);
      var everConnected = false;
      final states = transport.states.listen((state) {
        if (state == TransportState.connected) everConnected = true;
      });
      try {
        final record = await attempt(transport).timeout(pairingTimeout);
        if (!outcome.isCompleted) outcome.complete(record);
      } on CompanionPairingException catch (error) {
        onLog?.call('relay pairing leg failed: $error');
        if (isSharp(error)) sharp ??= error;
        relayNote = everConnected
            ? 'the relay was reached but the desktop never answered there'
            : 'no relay was reachable';
      } on Object catch (error) {
        onLog?.call('relay pairing leg failed: $error');
        relayNote = everConnected
            ? 'the relay was reached but the desktop never answered there'
            : 'no relay was reachable';
      } finally {
        await states.cancel();
        await closeTransport(transport);
      }
    }

    Future<void> lanLeg() async {
      if (scout == null) {
        lanNote = 'this phone cannot search this network for it';
        return;
      }
      final deadline = _now().add(pairingTimeout);
      final tried = <String>{};
      var sawBeacon = false;
      // A sharp refusal ends the search: the code itself is unusable.
      while (!cancelled &&
          !outcome.isCompleted &&
          sharp == null &&
          _now().isBefore(deadline)) {
        DiscoveredHost? candidate;
        for (final host in scout.candidates) {
          if (tried.contains(scout.keyOf(host))) continue;
          candidate = host;
          break;
        }
        if (candidate == null) {
          // No fresh candidate yet; the beacon repeats every two seconds.
          await Future<void>.delayed(const Duration(milliseconds: 150));
          continue;
        }
        sawBeacon = true;
        tried.add(scout.keyOf(candidate));
        final transport = scout.dial(candidate);
        open.add(transport);
        try {
          final record = await attempt(
            transport,
          ).timeout(scout.attemptTimeout * 4);
          scout.noteSuccess(candidate);
          if (!outcome.isCompleted) outcome.complete(record);
          return;
        } on CompanionPairingException catch (error) {
          onLog?.call('lan pairing attempt failed: $error');
          if (isSharp(error)) sharp ??= error;
          // Deliberately no scout cooldown: the user's Retry should be free
          // to dial the same desktop again right away.
        } on Object catch (error) {
          onLog?.call('lan pairing attempt failed: $error');
        } finally {
          await closeTransport(transport);
        }
      }
      if (!outcome.isCompleted) {
        lanNote = sawBeacon
            ? 'a desktop was seen on this network but did not accept the code'
            : 'no desktop was found on this network';
      }
    }

    unawaited(
      Future.wait([relayLeg(), lanLeg()]).then((_) {
        if (outcome.isCompleted) return;
        final specific = sharp;
        if (specific != null) {
          outcome.completeError(PairingException(specific.message));
          return;
        }
        outcome.completeError(
          PairingException(
            'Could not find your desktop — '
            '${relayNote ?? 'the relay was not tried'}, and '
            '${lanNote ?? 'this network was not searched'}. Make sure the '
            'pairing code is still on the desktop screen, then retry.',
          ),
        );
      }),
    );
    try {
      return await outcome.future;
    } finally {
      cancelled = true;
      for (final transport in open.toList()) {
        await closeTransport(transport);
      }
    }
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
    // Mid-cycle: a link that does not look healthy is torn down and re-dialled.
    if (_link.value != CompanionLinkState.connected) _declareDead();
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
    // The host's order IS the order — it is the desktop's own sort, and the
    // phone re-sorting it is what made the list jump. Archived rows are kept
    // and labelled rather than dropped, so the two lists agree.
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
          // Deliberately no session.unsubscribe: the session list keeps
          // every listed session subscribed anyway, and a redial rebuilds
          // the subscriptions from scratch.
        };
        unawaited(_primeTranscript(sessionId, controller));
      });

  @override
  Stream<CompanionApproval?> pendingApproval(String sessionId) =>
      _approvalOf(sessionId).stream;

  @override
  Future<void> sendPrompt(String sessionId, String text) async {
    await _ready;
    final client = _requireClient();
    await _mapRefusals(() => client.sendPrompt(sessionId, text));
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
  Stream<CompanionAttentionEvent> get attentionEvents => _attention.stream;

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
    await _progress.close();
  }

  // ------------------------------------------------------- connection loop

  Future<void> _loadStoredPairing() async {
    // Migrates a pre-multi-host store transparently: the single record it
    // holds becomes the sole saved connection, active.
    stored.CompanionConnections all;
    try {
      all = await stored.CompanionConnections.load(store);
    } on Object catch (error) {
      // Every public method awaits `_ready`, so a throw here would not merely
      // leave the phone unpaired — it would leave it *unusable*, silently,
      // for the rest of the launch. Start empty and say what happened.
      onLog?.call('reading the saved pairings failed: $error');
      all = stored.CompanionConnections();
    }
    if (_closed) return;
    _all = all;
    final record = all.active;
    _record = record;
    _pairing.value = record == null ? null : _publicPairing(record);
    _publishConnections();
    if (record != null) _startLoop();
  }

  void _publishConnections() => _connections.value = List.unmodifiable([
    for (final record in _all.records)
      CompanionConnection(
        hostId: record.hostId.value,
        name: record.hostName.isEmpty ? 'Desktop' : record.hostName,
        active: record.hostId.value == _all.activeHostId?.value,
        lastConnectedAt: record.lastConnectedAt,
      ),
  ]);

  /// Stamps "last connected" on the host that just came up, so the
  /// Connections list can order and label it. Best-effort: a store that
  /// refuses the write must never break a working link.
  Future<void> _noteConnected(stored.CompanionPairing record) async {
    try {
      _all = await stored.CompanionConnections.mutate(store, (all) {
        final saved = all.byHost(record.hostId.value);
        if (saved != null) all.upsert(saved.withLastConnected(_now()));
        return all;
      });
      if (_all.activeHostId?.value == record.hostId.value) {
        _record = _all.active ?? _record;
      }
      _publishConnections();
    } on Object catch (error) {
      onLog?.call('last-connected stamp failed: $error');
    }
  }

  CompanionPairing _publicPairing(stored.CompanionPairing record) =>
      CompanionPairing(
        capabilities: record.capabilities,
        hostName: record.hostName.isEmpty ? null : record.hostName,
        hostId: record.hostId,
      );

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

  /// A beacon while the relay carries the link: re-dial, LAN first. Gateway
  /// state survives — subscriptions rebuild, held transcripts re-read.
  void _onLanSighting(DiscoveredHost host) {
    final scout = lan;
    if (scout == null || _closed || _record == null) return;
    if (_link.value != CompanionLinkState.connected) return;
    if (_linkPath.value != CompanionLinkPath.relay) return;
    if (scout.inCooldown(host)) return;
    onLog?.call('beacon sighted; switching the link to the LAN');
    _declareDead();
  }

  Future<void> _connectLoop() async {
    try {
      while (!_closed && _record != null) {
        _link.value = CompanionLinkState.connecting;
        final client = await _dialAnyPath();
        if (client != null && !_closed && _record != null) {
          // The client bumped and persisted the generation counter — and, for
          // a relay path, the winning relay as the record's `relay`.
          _record = client.pairing;
          final won = _activeRelay;
          if (won != null) await _noteRelayOutcome(won, ok: true);
          _switching = false;
          unawaited(_noteConnected(client.pairing));
          _backoff.reset();
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
        final wait = _backoff.next();
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

  /// Design §3's priority order, widened by Loop 83 to a *set* of relays:
  ///
  /// 1. every fresh LAN candidate the beacon found;
  /// 2. the host's own LAN hint from `host.status`, when the beacon found
  ///    nothing — a network that eats multicast still has a direct path;
  /// 3. the last relay that actually worked;
  /// 4. the rest of the saved relays, skipping any still cooling from a recent
  ///    failure;
  /// 5. the app's configured default hosted relay, as a last resort.
  ///
  /// First success wins and is remembered as the last-known-good; each loser
  /// is torn down before the next is tried, so only one dial is ever in
  /// flight. Returns a connected client, or null when nobody answered.
  Future<CompanionClient?> _dialAnyPath() async {
    final scout = lan;
    if (scout != null) {
      var triedLan = false;
      for (final host in scout.candidates.take(3).toList()) {
        if (_closed || _record == null) return null;
        triedLan = true;
        final client = await _dialLan(scout, host);
        if (client != null) return client;
      }
      if (!triedLan) {
        final hinted = _lanHintHost(scout);
        if (hinted != null) {
          if (_closed || _record == null) return null;
          final client = await _dialLan(scout, hinted);
          if (client != null) return client;
        }
      }
    }
    for (final url in await _relayOrder()) {
      if (_closed || _record == null) return null;
      final client = await _dialRelay(url);
      if (client != null) return client;
    }
    return null;
  }

  /// The relays to try, in order. Falls back to the phone's configured relay
  /// setting, which is also what a typed-code pairing dials.
  Future<List<Uri>> _relayOrder() async {
    final record = _record;
    if (record == null) return const [];
    return orderRelayCandidates(
      record.candidates,
      fallback: await pairingRelay(),
      now: _now(),
    );
  }

  /// The host's announced LAN address as something [LanPathScout] can dial.
  /// A hint, not an identity: it may name a machine DHCP has since moved, and
  /// only the sealed hello decides whether whoever answers is the host.
  DiscoveredHost? _lanHintHost(LanPathScout scout) {
    final hint = parseLanHint(_record?.lanHint);
    if (hint == null) return null;
    final address = InternetAddress.tryParse(hint.host);
    if (address == null) return null;
    final candidate = DiscoveredHost(
      address: address,
      advert: LanAdvert(port: hint.port, tag: 'hint'),
      seenAt: _now(),
    );
    return scout.inCooldown(candidate) ? null : candidate;
  }

  Future<CompanionClient?> _dialLan(
    LanPathScout scout,
    DiscoveredHost host,
  ) async {
    final client = _newClient();
    final transport = scout.dial(host);
    _dialled = transport;
    _ownedTransport = transport;
    try {
      await client.connect(
        transport: transport,
        helloTimeout: scout.attemptTimeout,
      );
      // The sealed hello round-tripped: this host holds the paired key. The
      // beacon's cleartext was never trusted beyond "try dialling here".
      scout.noteSuccess(host);
      _linkPath.value = CompanionLinkPath.lan;
      onLog?.call('connected over the LAN');
      return client;
    } on Object catch (error) {
      // No sealed answer inside the timeout: a stranger, another pairing's
      // host, or a stale advert. Cool it down and let the relay carry on.
      onLog?.call('lan attempt failed: $error');
      scout.noteFailure(host);
      await _teardownClient();
      return null;
    }
  }

  /// One relay attempt. A failure stamps the candidate so the next reconnect
  /// skips it while it cools; a success is stamped by [_connectLoop] once the
  /// client has persisted its own generation bump.
  Future<CompanionClient?> _dialRelay(Uri url) async {
    final client = _newClient(relay: url);
    try {
      await client.connect(helloTimeout: helloTimeout);
      _linkPath.value = CompanionLinkPath.relay;
      _activeRelay = url;
      _noteTrouble(null);
      return client;
    } on Object catch (error) {
      onLog?.call('connect over $url failed: $error');
      // Why it failed, while the transport that failed is still around to
      // say so — a relay hanging up with "no peer" is not a network fault.
      final trouble = _troubleFor(error);
      await _teardownClient();
      await _noteRelayOutcome(url, ok: false);
      // Keep the last thing actually learned rather than replacing a real
      // reason with silence: the next candidate's transport has no story yet.
      _noteTrouble(trouble ?? _trouble);
      return null;
    }
  }

  /// Builds the client for one attempt. [relay] points the stored record at
  /// the candidate being tried — the client dials `pairing.relay` and, on
  /// success, persists that record, so the winner becomes the saved
  /// last-known-good with no extra write of our own.
  CompanionClient _newClient({Uri? relay}) {
    final record = _record!;
    final client = CompanionClient(
      pairing: relay == null ? record : record.withRelay(relay),
      store: store,
      relayFactory: _captureFactory,
      requestTimeout: requestTimeout,
      onLog: onLog,
    );
    _client = client;
    _clientEvents = client.events.listen(_onEvent);
    return client;
  }

  /// Records how one relay behaved. Best-effort: a store that refuses the
  /// write costs the phone a little ordering, never a working link.
  Future<void> _noteRelayOutcome(Uri url, {required bool ok}) async {
    final record = _record;
    if (record == null) return;
    final at = _now();
    try {
      _all = await stored.CompanionConnections.mutate(store, (all) {
        final saved = all.byHost(record.hostId.value);
        if (saved == null) return all;
        final key = url.toString();
        final next = <RelayCandidate>[];
        var found = false;
        for (final candidate in saved.candidates) {
          if (candidate.key != key) {
            next.add(candidate);
            continue;
          }
          found = true;
          next.add(ok ? candidate.succeededAt(at) : candidate.failedAt(at));
        }
        if (!found) {
          // The configured fallback is tried without being saved; it earns a
          // place in the set only by actually working.
          if (!ok) return all;
          next.add(RelayCandidate(url: url).succeededAt(at));
        }
        all.upsert(saved.copyWith(candidates: next));
        return all;
      });
      if (_all.activeHostId?.value == record.hostId.value) {
        _record = _all.active ?? _record;
      }
    } on Object catch (error) {
      onLog?.call('relay outcome stamp failed: $error');
    }
  }

  /// `notifications.register`, once per connection — only with the capability
  /// granted and a token source wired (Loop D's FCM). No source, a null
  /// token, or a refusal all skip silently: registration is plumbing.
  Future<void> _registerPushToken(CompanionClient client) async {
    final source = pushTokenSource;
    final record = _record;
    if (source == null || record == null) return;
    if (!record.capabilities.has(Capability.receiveNotifications)) return;
    try {
      final token = await source();
      if (token == null || _client != client || !client.isConnected) return;
      await client.registerNotifications(
        token: token.token,
        platform: token.platform,
      );
    } on Object catch (error) {
      onLog?.call('notifications.register failed: $error');
    }
  }

  RemoteTransport _captureFactory(Uri relay, RendezvousId rendezvous) {
    final transport = _relayFactory(relay, rendezvous);
    _dialled = transport;
    return transport;
  }

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
          _cancelLanHeal();
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
          // The transport re-dials the same rendezvous by itself; the
          // channel and its sequences survive the blip (loop 64's rule).
          if (_link.value == CompanionLinkState.connected) {
            _link.value = CompanionLinkState.connecting;
          }
          _armLanHeal();
        case TransportState.closed:
          _declareDead();
        case TransportState.idle:
          break;
      }
    });
  }

  /// Makes `connected` mean *the host answered*, after a socket came back.
  ///
  /// Re-sends the hello on the existing channel and waits for a fresh
  /// `host.status`. The host reattaches the transport, keeps the channel and
  /// its sequences and re-announces, so nothing about the key schedule moves.
  /// Silence means the phone is alone at the rendezvous — which is a dead
  /// link however healthy the socket looks — so the loop re-dials properly
  /// instead of parking on a "connected" that answers nothing.
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
  /// there is nothing to add beyond the banner's own words.
  ///
  /// Two ways to learn the same thing: the relay hung up with "no peer" after
  /// holding a lone socket for its timeout, or a dial found nobody at any
  /// rendezvous. Neither is a network failure, and telling someone to check
  /// their wifi when their desktop is simply closed wastes their afternoon.
  String? _troubleFor([Object? error]) {
    if (error is RemoteApiException && error.hostAbsent) {
      return _kHostAbsentTrouble;
    }
    final transport = _dialled;
    if (transport is RelayTransport &&
        transport.lastCloseCode == kRelayCloseNoPeer) {
      return _kHostAbsentTrouble;
    }
    return null;
  }

  /// What "nobody was at the rendezvous" reads like to someone holding a
  /// phone. Never "check your connection": the network is demonstrably fine,
  /// since the relay answered.
  static const String _kHostAbsentTrouble =
      'Your desktop is not answering on this relay — check that Chitragupta '
      'is running, and that it is set to the same relay.';

  void _noteTrouble(String? trouble) {
    if (_trouble == trouble) return;
    _trouble = trouble;
    // The banner reads this when the link state changes, which it is about
    // to; nudging the same value through keeps the two in step.
    _link.value = _link.value;
  }

  /// A LAN link that dropped redials forever on its own — but the host may
  /// simply be gone. Give it one attempt's grace, then declare the link dead
  /// so the loop heals to the relay instead of showing "connecting" all day.
  void _armLanHeal() {
    final scout = lan;
    if (scout == null || _linkPath.value != CompanionLinkPath.lan) return;
    _lanHealTimer ??= Timer(scout.attemptTimeout * 2, () {
      _lanHealTimer = null;
      if (_closed || _link.value == CompanionLinkState.connected) return;
      onLog?.call('lan link did not heal; falling back to the relay');
      _declareDead();
    });
  }

  void _cancelLanHeal() {
    _lanHealTimer?.cancel();
    _lanHealTimer = null;
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
      try {
        await _reloadTranscript(entry.key);
      } on Object catch (error) {
        onLog?.call('transcript recover for ${entry.key} failed: $error');
      }
    }
  }

  Future<void> _teardownClient() async {
    _cancelLanHeal();
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
    _lastHostStatus = null;
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
    _declareDead();
    final waiter = _backoffWaiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    await _teardownClient();
    if (!keepState) _link.value = CompanionLinkState.disconnected;
  }

  void _declareDead() {
    final died = _died;
    if (died != null && !died.isCompleted) died.complete();
  }

  // ------------------------------------------------------------ host events

  void _onEvent(CompanionEvent event) {
    switch (event) {
      case SessionChangedEvent(:final snapshot, :final raw):
        _applySnapshot(snapshot, raw: raw);
      case TranscriptAppendedEvent(:final page):
        _applyAppended(page);
      case ApprovalRequestedEvent(:final request):
        _applyApproval(request);
      case HostStatusEvent(:final status):
        _lastHostStatus = status;
        // The greeting that opens a connection arrives while the client is
        // still about to persist its own copy of the record; applying it here
        // would be overwritten by that write. The connect loop applies it once
        // the link is up. A later announcement — the host toggled a relay
        // under us — is applied at once, which is the whole point of it.
        if (_link.value == CompanionLinkState.connected) {
          unawaited(_applyHostStatus(status));
        }
    }
  }

  /// The refresh that removes re-pairing for good: the host says where it can
  /// be met, and this phone's saved candidates become that — health carried
  /// over for the relays that survive. A DHCP move retires the stale
  /// `ws://<old-ip>:<port>`; a hosted relay switched on months later simply
  /// shows up. An empty announcement (an older host) changes nothing, and a
  /// set that has not moved is not re-written.
  Future<void> _applyHostStatus(RemoteHostStatus status) async {
    final record = _record;
    if (record == null || _closed) return;
    if (status.relays.isEmpty && status.lanHint == null) return;
    final merged = mergeRelayCandidates(record.candidates, status.relays);
    final sameRelays =
        merged.length == record.candidates.length &&
        !merged.indexed.any((e) => e.$2.key != record.candidates[e.$1].key);
    final hint = status.lanHint ?? record.lanHint;
    if (sameRelays && hint == record.lanHint) return;
    try {
      _all = await stored.CompanionConnections.mutate(store, (all) {
        final saved = all.byHost(record.hostId.value);
        if (saved == null) return all;
        all.upsert(
          saved.copyWith(
            candidates: mergeRelayCandidates(saved.candidates, status.relays),
            lanHint: hint,
          ),
        );
        return all;
      });
      if (_all.activeHostId?.value == record.hostId.value) {
        _record = _all.active ?? _record;
      }
      onLog?.call('saved relay candidates refreshed from host.status');
    } on Object catch (error) {
      onLog?.call('relay candidate refresh failed: $error');
    }
  }

  void _applySnapshot(
    RemoteSessionSnapshot snapshot, {
    Map<String, Object?>? raw,
  }) {
    // Archived rows stay listed and say so; the desktop still holds them.
    final summary = _summaryOf(snapshot, raw: raw);
    final current = _sessions ?? const <CompanionSessionSummary>[];
    final next = <CompanionSessionSummary>[];
    var found = false;
    for (final session in current) {
      if (session.id == snapshot.sessionId) {
        found = true;
        next.add(summary);
      } else {
        next.add(session);
      }
    }
    if (!found) {
      // A late arrival goes where the host would have put it, not on the end:
      // beside its own project's rows, so the list does not reshuffle under
      // the user's thumb. A refresh then restores the host's exact order.
      next.insert(_placeFor(next, summary), summary);
    }
    _setSessions(next);
    _noteAttention(snapshot.sessionId, snapshot.attention, snapshot.title);
    if (!found) {
      final client = _client;
      if (client != null) {
        unawaited(_ensureSubscribed(client, snapshot.sessionId));
        // Re-read so the newcomer lands in the host's own ordering.
        unawaited(_refreshSessions());
      }
    }
  }

  /// Where a session the list has never held belongs: after the last row of
  /// its own project, or at the end when that project is new here too.
  int _placeFor(
    List<CompanionSessionSummary> list,
    CompanionSessionSummary arrival,
  ) {
    var place = list.length;
    for (var i = 0; i < list.length; i++) {
      if (list[i].projectKey == arrival.projectKey) place = i + 1;
    }
    return place;
  }

  void _applyAppended(RemoteTranscriptPage page) {
    final state = _transcripts[page.sessionId];
    if (state == null || !state.loaded || state.stale) return;
    if (page.cursor <= state.cursor) return;
    final needed = page.cursor - state.cursor;
    if (needed > page.messages.length) {
      // A stretch went missing (a reconnect raced the poll): re-read truth.
      unawaited(
        _reloadTranscript(page.sessionId).then(
          (_) {},
          onError: (Object error) =>
              onLog?.call('transcript reload failed: $error'),
        ),
      );
      return;
    }
    final delta = page.messages.sublist(page.messages.length - needed);
    state.messages = List.unmodifiable([
      ...state.messages,
      for (final message in delta)
        CompanionChatMessage(role: message.role, text: message.text),
    ]);
    state.cursor = page.cursor;
    _pushTranscript(state);
  }

  void _applyApproval(RemoteApprovalRequest request) {
    final approval = CompanionApproval(
      id: 'approval-${_nextApprovalId++}',
      sessionId: request.sessionId,
      // The wire carries no agent name, and the phone invents no claim.
      agentName: 'The agent',
      evidence: request.evidence,
      approveLabel: request.approveLabel,
      denyLabel: request.denyLabel,
    );
    _approvalOf(request.sessionId).value = approval;
    final summary = _currentSummary(request.sessionId);
    _noteAttention(
      request.sessionId,
      'needs_approval',
      summary?.title ?? request.sessionId,
    );
    _stampAttention(request.sessionId, CompanionAttentionKind.needsYou);
  }

  void _noteAttention(String sessionId, String? attention, String title) {
    final previous = _lastAttention[sessionId];
    if (previous == attention) return;
    _lastAttention[sessionId] = attention;
    final kind = _kindOf(attention);
    if (kind == null || _attention.isClosed) return;
    _attention.add(
      CompanionAttentionEvent(
        sessionId: sessionId,
        sessionTitle: title,
        kind: kind,
        at: _now().toUtc(),
        // Stamped from the host that is live right now. v1 keeps exactly one
        // link, so news can only come from the active desktop — carrying the
        // id is what lets a late event be checked against it after a switch.
        hostId: _record?.hostId.value,
      ),
    );
  }

  /// Marks one listed session as claiming attention — the coupling the
  /// host's own `session.changed` produces when its list already knows.
  void _stampAttention(String sessionId, CompanionAttentionKind kind) {
    final current = _sessions;
    if (current == null) return;
    var changed = false;
    final next = <CompanionSessionSummary>[];
    for (final session in current) {
      if (session.id != sessionId || session.attention?.kind == kind) {
        next.add(session);
        continue;
      }
      changed = true;
      next.add(
        session.copyWith(
          status: switch (kind) {
            CompanionAttentionKind.needsYou => CompanionSessionStatus.needsYou,
            CompanionAttentionKind.failed => CompanionSessionStatus.failed,
            CompanionAttentionKind.finished => session.status,
          },
          attention: CompanionAttention(kind: kind, at: _now().toUtc()),
        ),
      );
    }
    if (changed) _setSessions(next);
  }

  // ------------------------------------------------------------- transcripts

  Future<void> _primeTranscript(
    String sessionId,
    MultiStreamController<List<CompanionChatMessage>> controller,
  ) async {
    final state = _transcriptOf(sessionId);
    if (state.loaded) {
      controller.add(state.messages);
      return;
    }
    try {
      await _reloadTranscript(sessionId);
    } on Object catch (error) {
      if (state.listeners.contains(controller)) {
        controller.addError(_asGatewayError(error));
      }
    }
  }

  Future<void> _reloadTranscript(String sessionId) async {
    final client = _requireClient();
    await _ensureSubscribed(client, sessionId);
    final page = await _mapRefusals(() => client.transcript(sessionId));
    final state = _transcriptOf(sessionId);
    state.messages = List.unmodifiable([
      for (final message in page.messages)
        CompanionChatMessage(role: message.role, text: message.text),
    ]);
    state.cursor = page.cursor;
    state.loaded = true;
    state.stale = false;
    _pushTranscript(state);
  }

  void _pushTranscript(_TranscriptState state) {
    for (final listener in state.listeners.toList()) {
      listener.add(state.messages);
    }
  }

  // ---------------------------------------------------------------- helpers

  Future<void> _refreshSessions() => _refreshing ??= _refreshSessionsNow()
      .whenComplete(() => _refreshing = null);

  Future<void> _refreshSessionsNow() async {
    final client = _client;
    if (client == null || !client.isConnected) return;
    List<CompanionSessionSummary> list;
    try {
      list = await listSessions();
    } on GatewayException {
      return;
    }
    for (final session in list) {
      await _ensureSubscribed(client, session.id);
    }
  }

  Future<void> _ensureSubscribed(
    CompanionClient client,
    String sessionId,
  ) async {
    if (_subscribed.contains(sessionId)) return;
    try {
      await client.subscribeSession(sessionId);
      _subscribed.add(sessionId);
    } on Object catch (error) {
      onLog?.call('subscribe $sessionId failed: $error');
    }
  }

  CompanionClient _requireClient() {
    if (_record == null) throw const GatewayException(_kNotPaired);
    final client = _client;
    if (client == null ||
        !client.isConnected ||
        _link.value != CompanionLinkState.connected) {
      // Same reading as _mapRefusals: the link is not what it claims, so the
      // loop must re-dial. Without this the phone parks on a relay socket the
      // host has left — alone at the rendezvous, still reported "connected" —
      // and never dials again.
      _declareDead();
      throw const GatewayException(_kUnreachable);
    }
    return client;
  }

  /// Runs one request, rewriting every way it can fail into a sentence.
  Future<T> _mapRefusals<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on RemoteApiException catch (error) {
      if (error.code == null) {
        // Nobody answered: the link is not what it claims to be. Re-dial.
        _declareDead();
        throw const GatewayException(_kUnreachable);
      }
      throw GatewayException(_sentenceFor(error));
    } on TransportException {
      _declareDead();
      throw const GatewayException(_kUnreachable);
    } on StateError {
      throw const GatewayException(_kUnreachable);
    }
  }

  /// The protocol-error → user-sentence table.
  String _sentenceFor(RemoteApiException error) => switch (error.code!) {
    ErrorCode.notPermitted =>
      'The desktop did not grant this phone permission to do that. '
          'Re-pair with more access to use it.',
    ErrorCode.unsupportedVersion =>
      'This app and the desktop speak different protocol versions. '
          'Update whichever is older and pair again.',
    ErrorCode.notFound => 'The desktop no longer has that session.',
    ErrorCode.badRequest => 'The desktop refused: ${error.message}.',
    ErrorCode.unknownType =>
      'The desktop did not understand the request — one of the two apps '
          'is out of date.',
    ErrorCode.internal =>
      'Something went wrong on the desktop while handling that request.',
  };

  GatewayException _asGatewayError(Object error) =>
      error is GatewayException ? error : const GatewayException(_kUnreachable);

  void _setSessions(List<CompanionSessionSummary> list) {
    _sessions = List.unmodifiable(list);
    if (!_sessionChanges.isClosed) _sessionChanges.add(_sessions!);
  }

  CompanionSessionSummary? _currentSummary(String sessionId) {
    for (final session in _sessions ?? const <CompanionSessionSummary>[]) {
      if (session.id == sessionId) return session;
    }
    return null;
  }

  CompanionSessionSummary _summaryOf(
    RemoteSessionSnapshot snapshot, {
    Map<String, Object?>? raw,
  }) {
    final kind = _kindOf(snapshot.attention);
    CompanionAttention? attention;
    if (kind != null) {
      final previous = _currentSummary(snapshot.sessionId)?.attention;
      attention = previous != null && previous.kind == kind
          ? previous
          : CompanionAttention(kind: kind, at: _now().toUtc());
    }
    // The checkout facts the desktop card's third line is made of. They are
    // read straight off the row rather than through the typed snapshot: the
    // host that sends them is newer than this build's payload type, and a
    // host that does not simply leaves the line as it is today.
    String? text(String key) {
      final value = raw?[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    return CompanionSessionSummary(
      id: snapshot.sessionId,
      title: snapshot.title,
      // The host words the card's first line itself; an older host that
      // sent no label leaves only its own status word — the phone never
      // invents a claim about a process it cannot see.
      agentLabel: snapshot.agentLabel ?? snapshot.status.replaceAll('_', ' '),
      // The project the desktop's Explorer groups under, not the repository
      // inside it — one project holding several repos is one header here too.
      // Older hosts send no project, so the repository still answers.
      projectName:
          snapshot.projectName ?? snapshot.repositoryName ?? 'No project',
      projectId: snapshot.projectId ?? snapshot.repositoryId,
      projectPath: snapshot.projectPath,
      status: _statusOf(snapshot),
      whereabouts: snapshot.whereabouts,
      branch: text('branch'),
      subPath: text('subPath'),
      worktree: raw?['worktree'] == true,
      lastActivityAt: _parseInstant(snapshot.lastActivityAt),
      attention: attention,
      deliveryStage: snapshot.stage,
      imported: snapshot.imported,
      archived: snapshot.archived,
      folderMissing: snapshot.folderMissing || raw?['folderMissing'] == true,
    );
  }

  /// An ISO-8601 instant off the wire, or null for anything unreadable — a
  /// missing age renders as nothing, never as a guess.
  DateTime? _parseInstant(String? iso) =>
      iso == null ? null : DateTime.tryParse(iso)?.toUtc();

  CompanionSessionStatus _statusOf(RemoteSessionSnapshot snapshot) {
    if (snapshot.attention == 'needs_approval') {
      return CompanionSessionStatus.needsYou;
    }
    if (snapshot.attention == 'failed') return CompanionSessionStatus.failed;
    return switch (snapshot.status) {
      'running' => CompanionSessionStatus.working,
      'idle' ||
      'created' ||
      'completed' ||
      'cancelled' => CompanionSessionStatus.idle,
      'failed' => CompanionSessionStatus.failed,
      _ => CompanionSessionStatus.unknown,
    };
  }

  CompanionAttentionKind? _kindOf(String? attention) => switch (attention) {
    null => null,
    'needs_approval' => CompanionAttentionKind.needsYou,
    'failed' => CompanionAttentionKind.failed,
    'finished' => CompanionAttentionKind.finished,
    // A claim this build predates; "needs you" is the only safe reading of
    // a claim on the user.
    _ => CompanionAttentionKind.needsYou,
  };

  _TranscriptState _transcriptOf(String sessionId) =>
      _transcripts[sessionId] ??= _TranscriptState();

  _Watched<CompanionApproval?> _approvalOf(String sessionId) =>
      _approvals[sessionId] ??= _Watched(null);
}
