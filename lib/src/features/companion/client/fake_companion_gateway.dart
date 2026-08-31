/// A scripted [CompanionGateway] for tests and for running the companion UI
/// with no host wired.
library;

import 'dart:async';
import 'dart:convert';

import '../../remote/protocol.dart';
import 'companion_gateway.dart';

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

/// The id a scripted pairing that named no host gets, so a fake phone still
/// has one addressable connection. Host ids are 16 bytes of hex on the wire,
/// so the scripted ones are too — [DeviceId.parse] accepts nothing else.
String fakeHostId(int index) =>
    'fa4e${index.toRadixString(16).padLeft(4, '0')}'.padRight(32, '0');

final String _kFakeHostId = fakeHostId(0);

/// A scripted host id as a [DeviceId], or null for one a test invented that
/// is not 16 bytes of hex — the fake must not throw over a label.
DeviceId? _deviceId(String hostId) {
  try {
    return DeviceId.parse(hostId);
  } on Object {
    return null;
  }
}

/// The scripted gateway.
///
/// Constructed unpaired by default — the first-run experience. Use
/// [FakeCompanionGateway.paired] for a phone already talking to a host, and
/// the mutators ([setSessions], [setLink], [appendMessage], [raiseApproval],
/// [emitAttention]) to drive the UI from a test. Actions are recorded in
/// [sentPrompts] and [answeredApprovals].
///
/// Multi-host: pass [connections] for a phone with several saved desktops and
/// [sessionsByHost] for what each one holds, so a test can watch [switchTo]
/// swap the whole session list.
class FakeCompanionGateway implements CompanionGateway {
  FakeCompanionGateway({
    CompanionPairing? pairing,
    CompanionLinkState link = CompanionLinkState.disconnected,
    CompanionLinkPath? linkPath,
    List<CompanionSessionSummary> sessions = const [],
    Map<String, List<CompanionChatMessage>> transcripts = const {},
    Map<String, CompanionApproval> approvals = const {},
    this.validShortCode = 'ABCD1234',
    this.pairDelay = Duration.zero,
    CapabilitySet? grantOnPair,
    List<CompanionConnection> connections = const [],
    Map<String, List<CompanionSessionSummary>> sessionsByHost = const {},
    this.switchDelay = Duration.zero,
    this.failSwitchTo,
  }) : _pairing = _Watched(pairing),
       _link = _Watched(link),
       _linkPath = _Watched(
         link == CompanionLinkState.connected
             ? (linkPath ?? CompanionLinkPath.relay)
             : null,
       ),
       _sessions = _Watched(List.unmodifiable(sessions)),
       _grantOnPair = grantOnPair ?? CapabilitySet.all,
       _sessionsByHost = {
         for (final entry in sessionsByHost.entries)
           entry.key: List.unmodifiable(entry.value),
       },
       _connections = _Watched(
         List.unmodifiable(
           connections.isNotEmpty || pairing == null
               ? connections
               : [
                   CompanionConnection(
                     hostId: pairing.hostId?.value ?? _kFakeHostId,
                     name: pairing.hostName ?? 'Desktop',
                     active: true,
                   ),
                 ],
         ),
       ) {
    transcripts.forEach(
      (id, messages) =>
          _transcripts[id] = _Watched(List.unmodifiable(messages)),
    );
    approvals.forEach((id, approval) => _approvals[id] = _Watched(approval));
  }

  /// A phone already paired and connected — most screens' starting point.
  factory FakeCompanionGateway.paired({
    List<CompanionSessionSummary> sessions = const [],
    Map<String, List<CompanionChatMessage>> transcripts = const {},
    Map<String, CompanionApproval> approvals = const {},
    CompanionLinkState link = CompanionLinkState.connected,
    CompanionLinkPath? linkPath,
    CapabilitySet? capabilities,
    String hostName = 'Desktop',
    List<CompanionConnection> connections = const [],
    Map<String, List<CompanionSessionSummary>> sessionsByHost = const {},
    Duration switchDelay = Duration.zero,
    String? failSwitchTo,
  }) => FakeCompanionGateway(
    pairing: CompanionPairing(
      capabilities: capabilities ?? CapabilitySet.all,
      hostName: hostName,
    ),
    link: link,
    linkPath: linkPath,
    sessions: sessions,
    transcripts: transcripts,
    approvals: approvals,
    connections: connections,
    sessionsByHost: sessionsByHost,
    switchDelay: switchDelay,
    failSwitchTo: failSwitchTo,
  );

  /// The one short code [pairWithCode] accepts.
  final String validShortCode;

  /// A pause between pairing-progress stages, so a widget test can watch each
  /// one render. Zero (the default) keeps pairing effectively synchronous.
  final Duration pairDelay;

  /// A pause inside [switchTo] so a widget test can watch the connecting
  /// state render before the new host lands.
  final Duration switchDelay;

  /// A host id whose [switchTo] leaves the phone on it but disconnected —
  /// the scripted version of "the desktop you chose is not answering".
  final String? failSwitchTo;

  final CapabilitySet _grantOnPair;
  final _progress = StreamController<CompanionPairingProgress>.broadcast(
    sync: true,
  );
  Uri _pairingRelay = Uri.parse(kDefaultCompanionRelayUrl);
  final _Watched<CompanionPairing?> _pairing;
  final _Watched<CompanionLinkState> _link;
  final _Watched<CompanionLinkPath?> _linkPath;
  final _Watched<List<CompanionSessionSummary>> _sessions;
  final _Watched<List<CompanionConnection>> _connections;
  final Map<String, List<CompanionSessionSummary>> _sessionsByHost;
  final _transcripts = <String, _Watched<List<CompanionChatMessage>>>{};
  final _approvals = <String, _Watched<CompanionApproval?>>{};
  final _attention = StreamController<CompanionAttentionEvent>.broadcast(
    sync: true,
  );

  /// Every prompt the UI sent, in order.
  final sentPrompts = <({String sessionId, String text})>[];

  /// Every approval answer the UI sent, in order.
  final answeredApprovals =
      <
        ({
          String sessionId,
          String approvalId,
          CompanionApprovalDecision decision,
        })
      >[];

  /// How many times the UI asked for a reconnect.
  int reconnectRequests = 0;

  /// Every host id the UI asked to switch to, in order.
  final switchRequests = <String>[];

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
  CompanionLinkPath? get linkPath => _linkPath.value;

  @override
  Stream<CompanionLinkPath?> get linkPathStates => _linkPath.stream;

  /// The fake has no relay of its own; the screens that read this simply
  /// render the path without naming one.
  @override
  Uri? get activeRelay => null;

  @override
  CapabilitySet get capabilities =>
      _pairing.value?.capabilities ?? CapabilitySet.none;

  @override
  Future<CompanionPairing> pairWithQr(String qrPayload) async {
    Object? decoded;
    try {
      decoded = jsonDecode(qrPayload);
    } on FormatException {
      decoded = null;
    }
    if (decoded is! Map<String, Object?> ||
        decoded['secret'] is! String ||
        (decoded['secret'] as String).isEmpty) {
      throw _refuse(
        const PairingException(
          'That is not a Chitragupta pairing code. Show the QR code from the '
          "desktop's Remote access settings and scan it again.",
        ),
      );
    }
    return _pairStaged();
  }

  @override
  Future<CompanionPairing> pairWithCode(String shortCode) async {
    // The same sniff the real gateway does: a pasted payload is JSON.
    if (shortCode.trim().startsWith('{')) return pairWithQr(shortCode);
    if (shortCode.trim().toUpperCase() != validShortCode.toUpperCase()) {
      throw _refuse(
        const PairingException(
          'The host did not recognise that code. Codes expire after five '
          'minutes — show a fresh one on the desktop and try again.',
        ),
      );
    }
    return _pairStaged();
  }

  @override
  Stream<CompanionPairingProgress> get pairingProgress => _progress.stream;

  @override
  Future<Uri> pairingRelay() async => _pairingRelay;

  @override
  Future<void> setPairingRelay(Uri? url) async =>
      _pairingRelay = url ?? Uri.parse(kDefaultCompanionRelayUrl);

  PairingException _refuse(PairingException error) {
    _emit(CompanionPairingStage.failed, message: error.message);
    return error;
  }

  void _emit(
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

  Future<void> _gap() => pairDelay == Duration.zero
      ? Future<void>.value()
      : Future<void>.delayed(pairDelay);

  Future<CompanionPairing> _pairStaged() async {
    _emit(CompanionPairingStage.codeAccepted);
    await _gap();
    _emit(
      CompanionPairingStage.searching,
      detail: 'on this network and over the relay',
    );
    await _gap();
    _emit(
      CompanionPairingStage.proving,
      hostName: 'Desktop',
      capabilities: _grantOnPair,
    );
    await _gap();
    final paired = _pair();
    _emit(
      CompanionPairingStage.paired,
      hostName: 'Desktop',
      capabilities: paired.capabilities,
    );
    return paired;
  }

  CompanionPairing _pair() {
    // Pairing ADDS a desktop and switches to it; only re-pairing the same
    // host replaces its record.
    final hostId = fakeHostId(_connections.value.length);
    final paired = CompanionPairing(
      capabilities: _grantOnPair,
      hostName: 'Desktop',
      hostId: DeviceId.parse(hostId),
    );
    _pairing.value = paired;
    _connections.value = List.unmodifiable([
      for (final c in _connections.value)
        CompanionConnection(
          hostId: c.hostId,
          name: c.name,
          active: false,
          lastConnectedAt: c.lastConnectedAt,
        ),
      CompanionConnection(hostId: hostId, name: 'Desktop', active: true),
    ]);
    _link.value = CompanionLinkState.connected;
    _linkPath.value ??= CompanionLinkPath.relay;
    return paired;
  }

  // ------------------------------------------------------------ connections

  @override
  List<CompanionConnection> get connections => _connections.value;

  @override
  Stream<List<CompanionConnection>> get connectionsStates =>
      _connections.stream;

  @override
  Future<void> switchTo(String hostId) async {
    final target = _connections.value
        .where((c) => c.hostId == hostId)
        .firstOrNull;
    if (target == null) {
      throw const GatewayException(
        'That desktop is no longer saved on this phone.',
      );
    }
    if (target.active) return;
    switchRequests.add(hostId);
    // The old host's link and every derived state go first: nothing from it
    // may bleed into the new one.
    _link.value = CompanionLinkState.connecting;
    _sessions.value = const [];
    _transcripts.clear();
    for (final approval in _approvals.values) {
      approval.value = null;
    }
    _approvals.clear();
    _setActive(hostId);
    if (switchDelay != Duration.zero) await Future<void>.delayed(switchDelay);
    _pairing.value = CompanionPairing(
      capabilities: _grantOnPair,
      hostName: target.name,
      hostId: _deviceId(hostId),
    );
    if (failSwitchTo == hostId) {
      // Landed on the chosen desktop, but it is not answering — the banner
      // says so, exactly as it would after a relaunch.
      _link.value = CompanionLinkState.disconnected;
      _linkPath.value = null;
      return;
    }
    _sessions.value = List.unmodifiable(_sessionsByHost[hostId] ?? const []);
    _link.value = CompanionLinkState.connected;
    _linkPath.value = CompanionLinkPath.relay;
  }

  @override
  Future<void> removeConnection(String hostId) async {
    final wasActive = _connections.value
        .any((c) => c.hostId == hostId && c.active);
    final rest = [
      for (final c in _connections.value)
        if (c.hostId != hostId) c,
    ];
    if (!wasActive) {
      _connections.value = List.unmodifiable(rest);
      return;
    }
    if (rest.isEmpty) {
      _connections.value = const [];
      await unpair();
      return;
    }
    _connections.value = List.unmodifiable(rest);
    await switchTo(rest.first.hostId);
  }

  void _setActive(String hostId) => _connections.value = List.unmodifiable([
    for (final c in _connections.value)
      CompanionConnection(
        hostId: c.hostId,
        name: c.name,
        active: c.hostId == hostId,
        lastConnectedAt: c.lastConnectedAt,
      ),
  ]);

  @override
  Future<void> unpair() async {
    final active = _connections.value
        .where((c) => c.active)
        .firstOrNull
        ?.hostId;
    if (active != null && _connections.value.length > 1) {
      await removeConnection(active);
      return;
    }
    _connections.value = const [];
    _pairing.value = null;
    _link.value = CompanionLinkState.disconnected;
    _linkPath.value = null;
    _sessions.value = const [];
  }

  @override
  Future<void> reconnect() async {
    reconnectRequests++;
    if (_pairing.value != null) {
      _link.value = CompanionLinkState.connected;
      _linkPath.value ??= CompanionLinkPath.relay;
    }
  }

  // --------------------------------------------------------------- sessions

  @override
  Future<List<CompanionSessionSummary>> listSessions() async {
    _requireLink();
    return _sessions.value;
  }

  @override
  Stream<List<CompanionSessionSummary>> watchSessions() => _sessions.stream;

  @override
  Stream<List<CompanionChatMessage>> transcript(String sessionId) =>
      _transcriptOf(sessionId).stream;

  @override
  Stream<CompanionApproval?> pendingApproval(String sessionId) =>
      _approvalOf(sessionId).stream;

  @override
  Future<void> sendPrompt(String sessionId, String text) async {
    _requireLink();
    sentPrompts.add((sessionId: sessionId, text: text));
    appendMessage(sessionId, CompanionChatMessage(role: 'user', text: text));
  }

  @override
  Future<void> answerApproval(
    String sessionId,
    String approvalId,
    CompanionApprovalDecision decision,
  ) async {
    _requireLink();
    answeredApprovals.add((
      sessionId: sessionId,
      approvalId: approvalId,
      decision: decision,
    ));
    _approvalOf(sessionId).value = null;
  }

  @override
  Stream<CompanionAttentionEvent> get attentionEvents => _attention.stream;

  void _requireLink() {
    if (_pairing.value == null) {
      throw const GatewayException('This phone is not paired with a host.');
    }
    if (_link.value != CompanionLinkState.connected) {
      throw const GatewayException(
        'The host is unreachable right now, so nothing was sent.',
      );
    }
  }

  _Watched<List<CompanionChatMessage>> _transcriptOf(String sessionId) =>
      _transcripts[sessionId] ??= _Watched(const []);

  _Watched<CompanionApproval?> _approvalOf(String sessionId) =>
      _approvals[sessionId] ??= _Watched(null);

  // ------------------------------------------------------- test-side levers

  void setSessions(List<CompanionSessionSummary> sessions) =>
      _sessions.value = List.unmodifiable(sessions);

  void setLink(CompanionLinkState state) {
    _link.value = state;
    if (state != CompanionLinkState.connected) {
      _linkPath.value = null;
    } else {
      _linkPath.value ??= CompanionLinkPath.relay;
    }
  }

  /// Scripts which path the connected link claims to ride.
  void setLinkPath(CompanionLinkPath? path) => _linkPath.value = path;

  void appendMessage(String sessionId, CompanionChatMessage message) {
    final watched = _transcriptOf(sessionId);
    watched.value = List.unmodifiable([...watched.value, message]);
  }

  void raiseApproval(CompanionApproval approval) =>
      _approvalOf(approval.sessionId).value = approval;

  void clearApproval(String sessionId) => _approvalOf(sessionId).value = null;

  /// Emits the event and stamps the matching session's [CompanionAttention],
  /// the way a real host's `session.changed` would.
  void emitAttention(CompanionAttentionEvent event) {
    _sessions.value = List.unmodifiable([
      for (final session in _sessions.value)
        if (session.id == event.sessionId)
          session.copyWith(
            status: switch (event.kind) {
              CompanionAttentionKind.needsYou =>
                CompanionSessionStatus.needsYou,
              CompanionAttentionKind.failed => CompanionSessionStatus.failed,
              CompanionAttentionKind.finished => CompanionSessionStatus.idle,
            },
            lastActivityAt: event.at,
            attention: CompanionAttention(kind: event.kind, at: event.at),
          )
        else
          session,
    ]);
    _attention.add(event);
  }
}
