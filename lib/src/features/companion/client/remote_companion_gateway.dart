/// Loop 70's real protocol client behind Loop 71's [CompanionGateway] seam.
///
/// One adapter, no protocol logic of its own: pairing runs through
/// [CompanionPairingClient], the session API through [CompanionClient], and
/// reconnection through the transports' own backoff. What this file adds is
/// the contract the phone UI pinned: streams that seed their current value,
/// and every refusal rewritten as a sentence a user can read.
library;

import 'dart:async';

import '../../remote/client/companion_client.dart';
import '../../remote/client/companion_pairing_client.dart';
import '../../remote/client/companion_store.dart' as stored;
import '../../remote/domain/remote_payloads.dart';
import '../../remote/pairing/pairing_payload.dart';
import '../../remote/protocol.dart';
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

  /// Lifecycle only — never called with payload content.
  final void Function(String message)? onLog;

  final RelayTransportFactoryFn _relayFactory;

  /// Waits between full re-dials. Blips inside a connection are the
  /// transport's own backoff, not this one.
  final Backoff _backoff;

  final DateTime Function() _now;

  late final Future<void> _ready;

  stored.CompanionPairing? _record;
  CompanionClient? _client;
  StreamSubscription<CompanionEvent>? _clientEvents;
  RemoteTransport? _dialled;
  StreamSubscription<TransportState>? _transportStates;

  final _pairing = _Watched<CompanionPairing?>(null);
  final _link = _Watched<CompanionLinkState>(CompanionLinkState.disconnected);
  final _sessionChanges =
      StreamController<List<CompanionSessionSummary>>.broadcast(sync: true);
  final _attention = StreamController<CompanionAttentionEvent>.broadcast(
    sync: true,
  );

  List<CompanionSessionSummary>? _sessions;
  final _subscribed = <String>{};
  final _lastAttention = <String, String?>{};
  final _transcripts = <String, _TranscriptState>{};
  final _approvals = <String, _Watched<CompanionApproval?>>{};
  int _nextApprovalId = 1;

  bool _loopRunning = false;
  bool _closed = false;
  Completer<void>? _died;
  Completer<void>? _backoffWaiter;
  Future<void>? _refreshing;

  // ---------------------------------------------------------------- pairing

  @override
  CompanionPairing? get pairing => _pairing.value;

  @override
  Stream<CompanionPairing?> get pairingStates => _pairing.stream;

  @override
  CompanionLinkState get link => _link.value;

  @override
  Stream<CompanionLinkState> get linkStates => _link.stream;

  @override
  CapabilitySet get capabilities => _record?.capabilities ?? CapabilitySet.none;

  @override
  Future<CompanionPairing> pairWithQr(String qrPayload) async {
    await _ready;
    final PairingPayload payload;
    try {
      payload = PairingPayload.decode(qrPayload.trim());
    } on ProtocolException {
      throw const PairingException(
        'That is not a Chitragupta pairing code. Show the QR code from the '
        "desktop's Remote access settings and scan it again.",
      );
    } on ArgumentError {
      throw const PairingException(
        'That is not a Chitragupta pairing code. Show the QR code from the '
        "desktop's Remote access settings and scan it again.",
      );
    }
    // Re-pairing replaces the old host: drop the old link first so the new
    // record is the only one anything reads.
    await _dropLink();
    final pairingClient = CompanionPairingClient(
      store: store,
      deviceName: deviceName,
    );
    final stored.CompanionPairing record;
    try {
      record = await pairingClient.pair(payload);
    } on CompanionPairingException catch (error) {
      throw PairingException(error.message);
    } on Object catch (error) {
      onLog?.call('pairing failed: $error');
      throw const PairingException(
        'Pairing failed before the desktop could confirm it. Check the '
        'connection and scan a fresh code.',
      );
    }
    _record = record;
    final public = _publicPairing(record);
    _pairing.value = public;
    _backoff.reset();
    _startLoop();
    return public;
  }

  @override
  Future<CompanionPairing> pairWithCode(String shortCode) async {
    // Loop 70 shipped QR-only: no maintained pure-Dart SPAKE2 with RFC
    // vectors exists, and a low-entropy code without a PAKE would hand the
    // relay a brute-forceable secret. Say so instead of pretending.
    throw const PairingException(
      'This desktop offers QR pairing only. Open Remote access in its '
      'settings and scan the QR code it shows.',
    );
  }

  @override
  Future<void> unpair() async {
    await _ready;
    if (_record == null) return;
    try {
      await store.delete(stored.CompanionPairing.storeKey);
    } on Object catch (error) {
      onLog?.call('unpair delete failed: $error');
      throw const GatewayException(
        "The pairing could not be removed from this phone's secure storage. "
        'Try again.',
      );
    }
    _record = null;
    await _dropLink();
    _pairing.value = null;
    _sessions = null;
    if (!_sessionChanges.isClosed) _sessionChanges.add(const []);
    _subscribed.clear();
    _lastAttention.clear();
    for (final approval in _approvals.values) {
      approval.value = null;
    }
    for (final state in _transcripts.values) {
      state.loaded = false;
      state.cursor = 0;
      state.messages = const [];
    }
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
    final raw = await _mapRefusals(client.listSessions);
    final live = [
      for (final snapshot in raw)
        if (!snapshot.archived) snapshot,
    ];
    for (final snapshot in live) {
      // Seed the attention baseline silently: notifications are for news
      // that happens while we watch, not the state we walked in on.
      _lastAttention.putIfAbsent(snapshot.sessionId, () => snapshot.attention);
    }
    final list = [for (final snapshot in live) _summaryOf(snapshot)];
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
    await _teardownClient();
    _link.value = CompanionLinkState.disconnected;
    await _sessionChanges.close();
    await _attention.close();
  }

  // ------------------------------------------------------- connection loop

  Future<void> _loadStoredPairing() async {
    final record = await stored.CompanionPairing.load(store);
    if (_closed) return;
    _record = record;
    _pairing.value = record == null ? null : _publicPairing(record);
    if (record != null) _startLoop();
  }

  CompanionPairing _publicPairing(stored.CompanionPairing record) =>
      CompanionPairing(
        capabilities: record.capabilities,
        hostName: record.hostName.isEmpty ? null : record.hostName,
        hostId: record.hostId,
      );

  void _startLoop() {
    if (_loopRunning || _closed) return;
    _loopRunning = true;
    unawaited(_connectLoop());
  }

  Future<void> _connectLoop() async {
    try {
      while (!_closed && _record != null) {
        _link.value = CompanionLinkState.connecting;
        final client = CompanionClient(
          pairing: _record!,
          store: store,
          relayFactory: _captureFactory,
          requestTimeout: requestTimeout,
          onLog: onLog,
        );
        _client = client;
        _clientEvents = client.events.listen(_onEvent);
        var connected = false;
        try {
          await client.connect(helloTimeout: helloTimeout);
          connected = true;
        } on Object catch (error) {
          onLog?.call('connect failed: $error');
        }
        if (connected && !_closed && _record != null) {
          // The client bumped and persisted the generation counter.
          _record = client.pairing;
          _backoff.reset();
          _bindTransport(_dialled);
          _link.value = CompanionLinkState.connected;
          final died = _died = Completer<void>();
          unawaited(() async {
            try {
              await _recoverAfterConnect();
            } on Object catch (error) {
              onLog?.call('recover after connect failed: $error');
            }
          }());
          // Park here; blips are the transport's to heal. Only a request
          // nobody answered, a closed transport, unpair or close move on.
          await died.future;
          _died = null;
        }
        await _teardownClient();
        if (_closed || _record == null) break;
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
    _transportStates = transport.states.listen((state) {
      if (_client == null) return;
      switch (state) {
        case TransportState.connected:
          _link.value = CompanionLinkState.connected;
        case TransportState.connecting:
        case TransportState.disconnected:
          // The transport re-dials the same rendezvous by itself; the
          // channel and its sequences survive the blip (loop 64's rule).
          if (_link.value == CompanionLinkState.connected) {
            _link.value = CompanionLinkState.connecting;
          }
        case TransportState.closed:
          _declareDead();
        case TransportState.idle:
          break;
      }
    });
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
    final events = _clientEvents;
    _clientEvents = null;
    final states = _transportStates;
    _transportStates = null;
    final client = _client;
    _client = null;
    _dialled = null;
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
  }

  Future<void> _dropLink() async {
    _declareDead();
    final waiter = _backoffWaiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    await _teardownClient();
    _link.value = CompanionLinkState.disconnected;
  }

  void _declareDead() {
    final died = _died;
    if (died != null && !died.isCompleted) died.complete();
  }

  // ------------------------------------------------------------ host events

  void _onEvent(CompanionEvent event) {
    switch (event) {
      case SessionChangedEvent(:final snapshot):
        _applySnapshot(snapshot);
      case TranscriptAppendedEvent(:final page):
        _applyAppended(page);
      case ApprovalRequestedEvent(:final request):
        _applyApproval(request);
      case HostStatusEvent():
        break;
    }
  }

  void _applySnapshot(RemoteSessionSnapshot snapshot) {
    final summary = snapshot.archived ? null : _summaryOf(snapshot);
    final current = _sessions ?? const <CompanionSessionSummary>[];
    final next = <CompanionSessionSummary>[];
    var found = false;
    for (final session in current) {
      if (session.id == snapshot.sessionId) {
        found = true;
        if (summary != null) next.add(summary);
      } else {
        next.add(session);
      }
    }
    if (!found && summary != null) next.add(summary);
    _setSessions(next);
    _noteAttention(snapshot.sessionId, snapshot.attention, snapshot.title);
    if (!found && summary != null) {
      // News about a session the list never held: fold it in properly.
      final client = _client;
      if (client != null) {
        unawaited(_ensureSubscribed(client, snapshot.sessionId));
      }
    }
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
        CompanionSessionSummary(
          id: session.id,
          title: session.title,
          agentLabel: session.agentLabel,
          projectName: session.projectName,
          projectPath: session.projectPath,
          status: switch (kind) {
            CompanionAttentionKind.needsYou => CompanionSessionStatus.needsYou,
            CompanionAttentionKind.failed => CompanionSessionStatus.failed,
            CompanionAttentionKind.finished => session.status,
          },
          whereabouts: session.whereabouts,
          branch: session.branch,
          subPath: session.subPath,
          worktree: session.worktree,
          lastActivityAt: session.lastActivityAt,
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

  CompanionSessionSummary _summaryOf(RemoteSessionSnapshot snapshot) {
    final kind = _kindOf(snapshot.attention);
    CompanionAttention? attention;
    if (kind != null) {
      final previous = _currentSummary(snapshot.sessionId)?.attention;
      attention = previous != null && previous.kind == kind
          ? previous
          : CompanionAttention(kind: kind, at: _now().toUtc());
    }
    return CompanionSessionSummary(
      id: snapshot.sessionId,
      title: snapshot.title,
      // The wire names no agent, so this line carries only the host's own
      // status word — the phone never invents a claim about a process it
      // cannot see.
      agentLabel: snapshot.status.replaceAll('_', ' '),
      projectName: snapshot.repositoryName ?? 'No project',
      status: _statusOf(snapshot),
      attention: attention,
    );
  }

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
