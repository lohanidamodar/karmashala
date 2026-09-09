/// Loop 70's real protocol client behind Loop 71's [CompanionGateway] seam.
///
/// One adapter, no protocol logic of its own: pairing runs through
/// [CompanionPairingClient], the session API through [CompanionClient], and
/// reconnection through the transports' own backoff. What this file adds is
/// the contract the phone UI pinned: streams that seed their current value,
/// and every refusal rewritten as a sentence a user can read.
///
/// This file is the gateway's state and the [CompanionGateway] surface that
/// reads it; each family lives in a `part` beside it. A moved private member
/// is an `extension` on this class rather than a new library, because Dart
/// finds an extension member by unqualified name from inside the class and
/// from the other parts — so nothing was renamed to make the split. The
/// surface itself cannot move: an extension member does not satisfy
/// `implements`.
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
import '../../pairing/pairing_code.dart';
import '../../pairing/pairing_payload.dart';
import '../../protocol.dart';
import '../../transport/key_schedule.dart';
import '../../transport/lan_beacon.dart';
import '../../transport/relay_transport.dart';
import '../../transport/remote_transport.dart';
import 'companion_gateway.dart';

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

  /// Beacons still to be heard before the LAN is probed again, and how many
  /// the next failed promotion will ask for. See `_holdingOffPromotion`.
  ///
  /// Counted in beacons, never timed. The beacon is the event (§19), so a
  /// clock here would be a second opinion about a world the beacon is already
  /// reporting on — and a phone whose desktop has stopped beaconing stops
  /// re-probing for it, which is the right answer and one no timer can give.
  int _promotionHoldOff = 0;
  int _promotionPenalty = 0;

  /// True while a second link is being dialled and adopted.
  ///
  /// Guards against two promotions at once, and tells the liveness watch that
  /// a drop on the link being replaced is this promotion's own doing.
  bool _promoting = false;

  /// A drop on the link being replaced, held while a promotion decides. See
  /// `_releaseDeferredDrop`.
  bool _dropDeferred = false;

  /// What this phone last said about itself, resent whenever it changes.
  ///
  /// Held rather than derived so a report that arrives while the link is down
  /// is not lost: the next connection's registration carries it.
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
    final uploadId = await _uploadAttachment(
      client,
      sessionId,
      attachment,
      onProgress,
    );
    // The prompt is the commit: the host checks the length here, so a short
    // upload takes the prompt with it rather than becoming a truncated file an
    // agent is told to open.
    return _mapRefusals(
      () => client.sendPrompt(sessionId, text, attachmentId: uploadId),
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
