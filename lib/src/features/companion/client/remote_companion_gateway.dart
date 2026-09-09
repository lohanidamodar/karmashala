/// Loop 70's real protocol client behind Loop 71's [CompanionGateway] seam.
///
/// One adapter, no protocol logic of its own: pairing runs through
/// [CompanionPairingClient], the session API through [CompanionClient], and
/// reconnection through the transports' own backoff. What this file adds is
/// the contract the phone UI pinned: streams that seed their current value,
/// and every refusal rewritten as a sentence a user can read.
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:io';

import '../../remote/domain/companion_presence.dart';
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

part 'remote_companion_gateway_state.dart';
part 'remote_companion_gateway_refusals.dart';
part 'remote_companion_gateway_pairing.dart';
part 'remote_companion_gateway_connections.dart';
part 'remote_companion_gateway_connect_loop.dart';
part 'remote_companion_gateway_dial.dart';

/// The real gateway: [CompanionClient] + [CompanionPairingClient] over an
/// injected [stored.CompanionStore] (`SecureCompanionStore` on a phone).
class RemoteCompanionGateway implements CompanionGateway {
  RemoteCompanionGateway({
    required this.store,
    this.deviceName = 'Companion',
    this.deviceKind = CompanionDeviceKind.unknown,
    RelayTransportFactoryFn? relayFactory,
    this.requestTimeout = const Duration(seconds: 15),
    this.helloTimeout = const Duration(seconds: 8),
    this.linkHealGrace = const Duration(seconds: 10),
    this.pairingTimeout = const Duration(seconds: 20),
    this.lan,
    this.pushTokenSource,
    Backoff? reconnectBackoff,
    Backoff? localReconnectBackoff,
    DateTime Function()? now,
    this.onLog,
  }) : _relayFactory = relayFactory ?? _defaultRelayFactory,
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

  static RemoteTransport _defaultRelayFactory(
    Uri relay,
    RendezvousId rendezvous,
  ) => RelayTransport.connect(relay: relay, rendezvous: rendezvous);

  /// Where the pairing record lives — `SecureCompanionStore` on a real phone,
  /// a map-backed fake in tests.
  final stored.CompanionStore store;

  /// What the desktop's device list will call this phone.
  final String deviceName;

  /// What kind of thing this companion runs on, as `notifications.register`
  /// reports it. [CompanionDeviceKind.unknown] by default, because a build
  /// that has not been told must not guess.
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

  /// Waits between full re-dials. Blips inside a connection are the
  /// transport's own backoff, not this one.
  final Backoff _backoff;

  /// The same, for a desktop on this network. A schedule that climbs to half a
  /// minute is the right answer for an internet relay that may be down for
  /// good reasons; it is the wrong answer for a machine on the same table,
  /// where the honest expectation is that the link comes back in a moment.
  final Backoff _localBackoff;

  /// Whether the connection that just ended ran over something local — the
  /// LAN, or a relay at a private address. Decides which schedule the next
  /// wait comes from.
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
  /// is IN, not the one it moved to, so a redial reports `connecting` over and
  /// over; a stamp that moved on every report would call an hour-old outage
  /// fresh.
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

  /// Set while a deliberate host switch is tearing the old link down, so the
  /// loop dials the new desktop straight away instead of treating the drop as
  /// an outage to back off from.
  bool _switching = false;
  Completer<void>? _died;

  /// A death declared while the loop was between two of its own awaits, with
  /// no [_died] in existence to complete.
  ///
  /// The loop creates [_died] only after the dial has returned AND two awaited
  /// keystore writes have finished. Everything that can kill a link — a
  /// re-proof that found nobody, the LAN heal, a beacon, a request the host
  /// never answered, the user's own Retry — could land in that window and be
  /// thrown away, leaving the loop parked on a completer nothing would ever
  /// finish and the phone reading "Connecting…" until it was force-quit.
  bool _deathPending = false;

  /// Set when the pass in flight has been overtaken: the user asked to retry,
  /// or a pairing, a switch or an unpair has already chosen a different
  /// desktop. Distinct from [_deathPending] on purpose — a request that found
  /// the link down is news about the link, not a reason to abandon the dial
  /// that is busy fixing it.
  bool _dialOvertaken = false;
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
  /// worth adding to the banner's own words. Watched, because it changes
  /// without the link state changing with it.
  final _trouble = _Watched<String?>(null);
  bool _lanStarted = false;
  StreamSubscription<DiscoveredHost>? _lanSightings;
  /// Runs while a dropped transport is being given its chance to come back.
  Timer? _healTimer;

  /// Beacon hosts whose direct dial has failed, by [LanPathScout.keyOf], with
  /// when — read only by the beacon's *upgrade*, never by the dial path.
  ///
  /// The beacon repeats every two seconds and the scout's grudge lasts two
  /// minutes, so a desktop that is audible but not dialable — a firewall on
  /// its LAN port is the ordinary cause — used to make the phone throw away a
  /// working relay link every two minutes, for ever. Trying once is right;
  /// trying again on a schedule, and paying for it with the link that works,
  /// is not.
  final _lanUpgradeRefused = <String, DateTime>{};

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
  static const String kPairingRelayStoreKey = 'karmashala.companion.relay';

  /// Where this phone's own identity lives — beside the pairing records
  /// rather than inside one, because it must outlive unpairing every host.
  static const String kDeviceIdStoreKey = 'karmashala.remote.device_id';

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
      // give up: an escaping `TimeoutException` is an unhandled async error
      // that leaves the tap looking like it did nothing at all.
      onLog?.call('switchTo failed: $error');
      throw const GatewayException(
        "This phone could not record which desktop to use, so it stayed on "
        'the one it was on. Try again.',
      );
    }
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
    // **The schedule, not just the wait in front of it.** Every caller of this
    // is a reason to believe the world changed — the app came back to the
    // foreground, the user asked, a desktop was picked — and a schedule that
    // kept its attempt count answered the very next failure with the delay it
    // had climbed to while nobody was watching. Skipping one wait and then
    // waiting sixteen seconds is not what "reconnect now" means.
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
    // Mid-cycle: a link that does not look healthy is torn down and
    // re-dialled — including one still dialling, which abandons the
    // candidates it has left rather than making the user wait them out.
    if (_link.value != CompanionLinkState.connected) {
      _dialOvertaken = true;
      _declareDead();
      return;
    }
    // The link SAYS it is up. After a resume that is a claim about a socket
    // nobody watched while the app was frozen, so it is proved rather than
    // taken: one hello, one `host.status`, and silence declares it dead. The
    // alternative is waiting out the heartbeat with a corpse on screen.
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
  Stream<CompanionActivity> activity(String sessionId) =>
      Stream.multi((controller) {
        final watched = _activityOf(sessionId);
        final subscription = watched.stream.listen(controller.add);
        controller.onCancel = subscription.cancel;
        // Asked outright once, because the host states this unprompted and an
        // unprompted frame cannot be replayed for a screen that opened after
        // it. Everything after this arrives on its own.
        unawaited(_primeActivity(sessionId));
      });

  /// Reads the current activity from the host, and words its refusal when it
  /// has one.
  ///
  /// A pairing without `view_activity` is refused here, in a sentence, and the
  /// sentence is what the screen shows — never an empty list, which would say
  /// the session is running nothing.
  Future<void> _primeActivity(String sessionId) async {
    try {
      await _ready;
      final client = _client;
      if (client == null) return;
      final activity = await client.activity(sessionId);
      _acceptActivity(activity);
    } on RemoteApiException catch (error) {
      _activityOf(sessionId).value = CompanionActivity(
        at: _now(),
        refused: error.message,
      );
    } on Object catch (error) {
      onLog?.call('activity for a session could not be read: $error');
    }
  }

  /// Folds one `session.activity` reading in, whether it was asked for or
  /// stated.
  void _acceptActivity(RemoteSessionActivity activity) {
    _activityOf(activity.sessionId).value = CompanionActivity(
      at: _now(),
      absence: activity.absence,
      calls: [
        for (final call in activity.calls)
          CompanionActivityCall(
            summary: call.summary,
            subagent: call.subagent,
            // Both instants are the host's, so this duration is the one number
            // here that needs no clock of ours.
            elapsed: _nonNegative(activity.observedAt.difference(call.startedAt)),
          ),
      ],
    );
  }

  static Duration _nonNegative(Duration value) =>
      value.isNegative ? Duration.zero : value;

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
    // new session's row and its transcript subscription already there rather
    // than waiting out a poll on an empty view.
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

  void _ensureCurrentClient(CompanionClient client) {
    if (identical(_client, client)) return;
    throw const GatewayException(
      'The desktop changed while this request was in flight. Nothing was applied to the new desktop.',
    );
  }

  @override
  Future<RemotePromptDelivery> sendPrompt(
    String sessionId,
    String text, {
    CompanionOutgoingAttachment? attachment,
    void Function(int sent, int total)? onProgress,
  }) async {
    await _ready;
    final client = _requireClient();
    if (attachment == null) {
      return _mapRefusals(() => client.sendPrompt(sessionId, text));
    }
    // Declared first, so a refusal costs one small frame rather than the
    // megabytes of a photo the desktop cannot use.
    final offer = await _mapRefusals(
      () => client.beginAttachment(
        RemoteAttachmentBegin(
          sessionId: sessionId,
          name: attachment.name,
          mediaType: attachment.mediaType,
          bytes: attachment.bytes.length,
        ),
      ),
    );
    final total = (attachment.bytes.length / offer.chunkBytes).ceil();
    onProgress?.call(0, total);
    var seq = 0;
    for (var at = 0; at < attachment.bytes.length; at += offer.chunkBytes) {
      final end = at + offer.chunkBytes < attachment.bytes.length
          ? at + offer.chunkBytes
          : attachment.bytes.length;
      // Awaited one at a time. The outbound queue drops its oldest frame under
      // pressure, so a slice nobody acknowledged is a slice that is gone.
      await _mapRefusals(
        () => client.sendAttachmentChunk(
          offer.uploadId,
          seq,
          Uint8List.sublistView(attachment.bytes, at, end),
        ),
      );
      onProgress?.call(++seq, total);
    }
    // The prompt is the commit: the host checks the length here, so a short
    // upload takes the prompt with it rather than becoming a truncated file an
    // agent is told to open.
    return _mapRefusals(
      () => client.sendPrompt(sessionId, text, attachmentId: offer.uploadId),
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

  // ------------------------------------------------------- connection loop

  /// What this phone last said about itself, resent whenever it changes.
  ///
  /// Held rather than derived so a report that arrives while the link is down
  /// is not lost: the next connection's registration carries it.
  CompanionPresence _presence = CompanionPresence.unknown;

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

  /// One frame per change, and **never a tick**: an unchanged presence sends
  /// nothing at all, so the frame count on the wire follows what actually
  /// happened on the phone.
  Future<void> _report(CompanionPresence next) async {
    final proposed = next.copyWith(deviceKind: deviceKind);
    if (proposed.saysSameAs(_presence)) return;
    _presence = proposed;
    final client = _client;
    // Nothing is queued for a link that is down: the next connection registers
    // anyway, and it carries whatever the latest answer is by then.
    if (client == null || !client.isConnected) return;
    await _registerPushToken(client);
  }

  /// `notifications.register`, once per connection and again on every change
  /// of presence — only with the capability granted and a token source wired
  /// (Loop D's FCM). No source, a null token, or a refusal all skip silently:
  /// registration is plumbing.
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
        presence: _presence,
      );
    } on Object catch (error) {
      onLog?.call('notifications.register failed: $error');
    }
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
    if (error is RemoteApiException) {
      // "The relay would not take the socket" and "nobody was at the
      // rendezvous" are different facts and deserve different sentences: one
      // is about the meeting place, the other about the desktop. Telling
      // someone to go and check a desktop that is awake is as useless as
      // telling them to check a network that works.
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

  /// What "nobody was at the rendezvous" reads like to someone holding a
  /// phone. Never "check your connection": the network is demonstrably fine,
  /// since the relay answered.
  static const String _kHostAbsentTrouble =
      'Your desktop is not answering on this relay — check that Karmashala '
      'is running, and that it is set to the same relay.';

  /// And what "the meeting place itself would not answer" reads like. Never
  /// about the desktop: nothing here has learned anything about it yet.
  static const String _kRelayUnreachableTrouble =
      'This phone could not reach the relay your desktop uses. On mobile data '
      'that usually means the desktop is only reachable on its own network.';

  void _noteTrouble(String? trouble) {
    if (_trouble.value == trouble) return;
    // Said on its own stream, because it is learned on its own. A dial that
    // failed while the phone was already `connecting` changes no link state,
    // and re-emitting an unchanged one rebuilds nothing — so the first pass
    // after launch used to show a bare "Connecting to your desktop…" with the
    // reason already sitting in this field.
    _trouble.value = trouble;
  }

  /// A transport that dropped redials its OWN endpoint forever, and that
  /// endpoint may be one nobody is at any more — the desktop's LAN address
  /// moved under it, or the relay it was reached through went away. Nothing
  /// else watches that: the re-proof only runs when a socket comes BACK, so a
  /// transport stuck in `connecting` is a loop parked on a completer that
  /// will never fire and a phone reading "Connecting…" for ever.
  ///
  /// So give the transport one grace period to heal itself, and then declare
  /// the link dead. That costs nothing when it was a blip — the link is
  /// already down when the timer fires — and it is what lets the loop re-read
  /// the candidate set, which is where the desktop's NEW address is.
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
      // Resume from the cursor rather than re-read the tail. A phone that was
      // away for a hundred turns is entitled to all hundred, and the tail is
      // only the last page of them — the rest simply stopped existing, with a
      // notice about "earlier messages" standing in for turns this phone had
      // already been shown. `stale` is cleared first because the appends it
      // blocks are precisely the ones being fetched here.
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
    // [_lastHostStatus] deliberately survives. It is what the host said about
    // *itself* — where it can be met — not anything about the connection that
    // just ended, and the announcement that matters most is the one that
    // arrives seconds before a link dies: a local relay whose address moved
    // announces the new one and then re-points its listeners, which takes the
    // old socket down with it. Clearing it here meant a phone that heard "I
    // have moved to :52918" while still coming up forgot it the instant that
    // half-open connect failed, and then spent forever redialling the address
    // it had already been told was dead. See [_relayOrder].
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

  // ------------------------------------------------------------ host events

  void _onEvent(CompanionEvent event) {
    switch (event) {
      case SessionChangedEvent(:final snapshot, :final raw):
        _applySnapshot(snapshot, raw: raw);
      case TranscriptAppendedEvent(:final page):
        _applyAppended(page);
      case SessionActivityEvent(:final activity):
        _acceptActivity(activity);
      case ApprovalRequestedEvent(:final request):
        _applyApproval(request);
      case ApprovalResolvedEvent(:final resolution):
        _retireApproval(
          resolution.sessionId,
          switch (resolution.outcome) {
            RemoteApprovalOutcome.approved =>
              CompanionApprovalOutcome.approved,
            RemoteApprovalOutcome.denied => CompanionApprovalOutcome.denied,
            RemoteApprovalOutcome.elsewhere =>
              CompanionApprovalOutcome.elsewhere,
          },
        );
      case PairingRevokedEvent():
        // The one case where silence would have been read as a busy desktop.
        // Now it is a fact, so the link stops claiming anything else.
        _revoked = true;
        onLog?.call('the host revoked this pairing; the link is over');
        _link.value = CompanionLinkState.disconnected;
        _declareDead();
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
    // Re-derived, never accumulated. The event above is the live path, and
    // this is what covers a phone that was asleep for it: every snapshot —
    // including the one `session.subscribe` pushes on reconnect — carries
    // whether the session is still asking, so a card the phone kept through a
    // dead link is retired the moment it hears the truth again.
    if (snapshot.attention != kAttentionNeedsApproval) {
      _retireApproval(snapshot.sessionId, CompanionApprovalOutcome.elsewhere);
    }
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
      _startReload(page.sessionId);
      return;
    }
    final delta = page.messages.sublist(page.messages.length - needed);
    state.messages = List.unmodifiable([
      // A turn arriving is the reason going away: "there is nothing to read
      // here" cannot stand above something to read, whatever the host said
      // when the transcript was still empty.
      for (final message in state.messages)
        if (message.role != kCompanionAbsenceRole) message,
      for (final message in delta)
        CompanionChatMessage(role: message.role, text: message.text),
    ]);
    state.cursor = page.cursor;
    _pushTranscript(state);
    // A live page is bounded too, so one is not necessarily all of it.
    if (page.hasNewer) _startDrain(page.sessionId);
  }

  /// Kicks a gap recovery that nothing is waiting on, and swallows nothing.
  void _startDrain(String sessionId) {
    unawaited(
      _drainNewer(sessionId).then(
        (complete) {
          // A page that would not join on is a transcript that moved under us;
          // only a full re-read settles it.
          if (!complete) _startReload(sessionId);
        },
        onError: (Object error) {
          onLog?.call('transcript drain for $sessionId failed: $error');
          _startReload(sessionId);
        },
      ),
    );
  }

  void _startReload(String sessionId) {
    unawaited(
      _reloadTranscript(sessionId).then(
        (_) {},
        onError: (Object error) =>
            onLog?.call('transcript reload failed: $error'),
      ),
    );
  }

  void _applyApproval(RemoteApprovalRequest request) {
    final approval = CompanionApproval(
      id: 'approval-${_nextApprovalId++}',
      sessionId: request.sessionId,
      // The wire carries no agent name, and the phone invents no claim.
      agentName: 'The agent',
      evidence: request.evidence,
      waiting: request.waiting,
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

  /// Takes a card off the screen and says why.
  ///
  /// The nothing-to-do case is deliberately silent: a `session.changed` for a
  /// session that was never asking must not announce a resolution the reader
  /// never saw a request for.
  void _retireApproval(String sessionId, CompanionApprovalOutcome outcome) {
    final pending = _approvalOf(sessionId);
    if (pending.value == null) return;
    pending.value = null;
    if (!_approvalResolutions.isClosed) {
      _approvalResolutions.add(
        CompanionApprovalResolution(sessionId: sessionId, outcome: outcome),
      );
    }
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

  /// Sessions with a gap recovery in flight, so two never race each other.
  final _draining = <String>{};

  /// Pages forward from what this phone holds until the host says there is
  /// nothing newer, and answers whether it got there.
  ///
  /// **The rule the reconnect path turns on.** A page is bounded, so one answer
  /// is not an answer: recovery is finished when, and only when, `hasNewer`
  /// reads false. Re-reading the tail instead — which is what a reconnect used
  /// to do — is correct only while the gap is smaller than a page; past that it
  /// replaces the conversation with its end and says so in a line the reader
  /// has no reason to connect to the turns that went missing.
  ///
  /// False means the pages stopped joining on to what is held, which is a
  /// transcript that moved under us (a rotated store, a compaction) rather than
  /// a gap. Only a full re-read settles that, and the caller does it.
  Future<bool> _drainNewer(String sessionId) async {
    if (!_draining.add(sessionId)) return true;
    try {
      while (true) {
        final state = _transcripts[sessionId];
        if (state == null || !state.loaded) return false;
        final client = _client;
        if (client == null) return false;
        await _ensureSubscribed(client, sessionId);
        final page = await _mapRefusals(
          () => client.transcript(sessionId, after: state.cursor),
        );
        if (!_appendResumed(sessionId, page)) return false;
        // An older host says nothing here, which decodes as false — and false
        // is what it meant: it answered with the whole remainder.
        if (!page.hasNewer) return true;
      }
    } finally {
      _draining.remove(sessionId);
    }
  }

  /// Appends one resumed page, or answers false when it does not join on.
  ///
  /// Keyed by the id this phone *asked* with, never [RemoteTranscriptPage
  /// .sessionId] — a superseded imported id is answered under the live one, and
  /// the screen is still watching the id it opened.
  bool _appendResumed(String sessionId, RemoteTranscriptPage page) {
    final state = _transcripts[sessionId];
    if (state == null || !state.loaded) return false;
    // The host windows from where it was asked, so a contiguous page opens
    // exactly at the cursor. Anything else is a transcript that shrank.
    if (page.omitted != state.cursor) return false;
    if (page.messages.isEmpty) {
      state.cursor = page.cursor;
      return true;
    }
    state.messages = List.unmodifiable([
      // A turn arriving is the reason going away, as on the live path.
      for (final message in state.messages)
        if (message.role != kCompanionAbsenceRole) message,
      for (final message in page.messages)
        CompanionChatMessage(role: message.role, text: message.text),
    ]);
    state.cursor = page.cursor;
    state.stale = false;
    _pushTranscript(state);
    return true;
  }

  Future<void> _reloadTranscript(String sessionId) async {
    final client = _requireClient();
    await _ensureSubscribed(client, sessionId);
    final page = await _mapRefusals(() => client.transcript(sessionId));
    final state = _transcriptOf(sessionId);
    state.messages = List.unmodifiable([
      // Said, not hidden. The host sends the tail of a long conversation
      // because the whole of one does not fit in a frame, and a view that
      // simply began in the middle would read as a transcript that had lost
      // its start rather than one showing its end.
      if (page.omitted > 0)
        CompanionChatMessage(
          role: kCompanionNoticeRole,
          text: '${page.omitted} earlier messages are not loaded — this is '
              'the top of what the phone has. The desktop holds the whole '
              'conversation.',
        ),
      // Which nothing this is, in the phone's words, from the host's fact.
      // Only when there is genuinely nothing: a reason beside turns would be
      // describing a transcript that exists.
      if (page.messages.isEmpty) ?_absenceRow(page.absence),
      for (final message in page.messages)
        CompanionChatMessage(role: message.role, text: message.text),
    ]);
    state.cursor = page.cursor;
    state.loaded = true;
    state.stale = false;
    _pushTranscript(state);
  }

  /// The host's reason for an empty transcript, in the phone's own words.
  ///
  /// Null for a nothing nobody accounted for — an older desktop, or a reason
  /// this build has never heard of — which leaves the screen's hedged hint in
  /// place rather than inventing a specific claim.
  CompanionChatMessage? _absenceRow(RemoteTranscriptAbsence? absence) =>
      switch (absence) {
        RemoteTranscriptAbsence.noChatView => const CompanionChatMessage(
          role: kCompanionAbsenceRole,
          // The desktop's own sentence for this session, minus the half a
          // phone cannot act on: it has no terminal to look at.
          text:
              'This agent keeps no transcript this app can read, so there is '
              'no chat view for it — on the desktop or here. Its terminal is '
              'the session, and the desktop is where that lives. Messages you '
              'send from here still reach it.',
        ),
        // The same refusal about a conversation rather than an agent, so it
        // does not say "this agent" about a store whose other sessions read
        // perfectly well.
        RemoteTranscriptAbsence.noTranscriptFile => const CompanionChatMessage(
          role: kCompanionAbsenceRole,
          text:
              'This session\'s store kept the conversation and no transcript '
              'this app can read beside it, so there is no chat view for it — '
              'on the desktop or here. Its terminal is the session, and the '
              'desktop is where that lives. Messages you send from here still '
              'reach it.',
        ),
        null => null,
      };

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

  /// Requests that have gone unanswered with nothing answered between them.
  int _unanswered = 0;

  /// Set when the host says the pairing is gone. Never cleared: the device key
  /// went with it, so this link cannot come back — only a fresh pairing can.
  bool _revoked = false;

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
      attachments: snapshot.attachments,
      environmentBadge: snapshot.environmentBadge ?? text('environmentBadge'),
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

  _Watched<CompanionActivity> _activityOf(String sessionId) =>
      _activity[sessionId] ??= _Watched(CompanionActivity.unknown);
}
