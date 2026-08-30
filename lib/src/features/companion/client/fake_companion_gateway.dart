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

/// The scripted gateway.
///
/// Constructed unpaired by default — the first-run experience. Use
/// [FakeCompanionGateway.paired] for a phone already talking to a host, and
/// the mutators ([setSessions], [setLink], [appendMessage], [raiseApproval],
/// [emitAttention]) to drive the UI from a test. Actions are recorded in
/// [sentPrompts] and [answeredApprovals].
class FakeCompanionGateway implements CompanionGateway {
  FakeCompanionGateway({
    CompanionPairing? pairing,
    CompanionLinkState link = CompanionLinkState.disconnected,
    List<CompanionSessionSummary> sessions = const [],
    Map<String, List<CompanionChatMessage>> transcripts = const {},
    Map<String, CompanionApproval> approvals = const {},
    this.validShortCode = 'ABCD1234',
    CapabilitySet? grantOnPair,
  }) : _pairing = _Watched(pairing),
       _link = _Watched(link),
       _sessions = _Watched(List.unmodifiable(sessions)),
       _grantOnPair = grantOnPair ?? CapabilitySet.all {
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
    CapabilitySet? capabilities,
    String hostName = 'Desktop',
  }) => FakeCompanionGateway(
    pairing: CompanionPairing(
      capabilities: capabilities ?? CapabilitySet.all,
      hostName: hostName,
    ),
    link: link,
    sessions: sessions,
    transcripts: transcripts,
    approvals: approvals,
  );

  /// The one short code [pairWithCode] accepts.
  final String validShortCode;

  final CapabilitySet _grantOnPair;
  final _Watched<CompanionPairing?> _pairing;
  final _Watched<CompanionLinkState> _link;
  final _Watched<List<CompanionSessionSummary>> _sessions;
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
      throw const PairingException(
        'That is not a Chitragupta pairing code. Show the QR code from the '
        "desktop's Remote access settings and scan it again.",
      );
    }
    return _pair();
  }

  @override
  Future<CompanionPairing> pairWithCode(String shortCode) async {
    if (shortCode.trim().toUpperCase() != validShortCode.toUpperCase()) {
      throw const PairingException(
        'The host did not recognise that code. Codes expire after five '
        'minutes — show a fresh one on the desktop and try again.',
      );
    }
    return _pair();
  }

  CompanionPairing _pair() {
    final paired = CompanionPairing(
      capabilities: _grantOnPair,
      hostName: 'Desktop',
    );
    _pairing.value = paired;
    _link.value = CompanionLinkState.connected;
    return paired;
  }

  @override
  Future<void> unpair() async {
    _pairing.value = null;
    _link.value = CompanionLinkState.disconnected;
  }

  @override
  Future<void> reconnect() async {
    reconnectRequests++;
    if (_pairing.value != null) _link.value = CompanionLinkState.connected;
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

  void setLink(CompanionLinkState state) => _link.value = state;

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
          CompanionSessionSummary(
            id: session.id,
            title: session.title,
            agentLabel: session.agentLabel,
            projectName: session.projectName,
            projectPath: session.projectPath,
            status: switch (event.kind) {
              CompanionAttentionKind.needsYou =>
                CompanionSessionStatus.needsYou,
              CompanionAttentionKind.failed => CompanionSessionStatus.failed,
              CompanionAttentionKind.finished => CompanionSessionStatus.idle,
            },
            whereabouts: session.whereabouts,
            branch: session.branch,
            subPath: session.subPath,
            worktree: session.worktree,
            lastActivityAt: event.at,
            attention: CompanionAttention(kind: event.kind, at: event.at),
          )
        else
          session,
    ]);
    _attention.add(event);
  }
}
