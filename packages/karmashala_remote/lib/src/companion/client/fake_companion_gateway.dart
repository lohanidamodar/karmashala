/// A scripted [CompanionGateway] for tests and for running the companion UI
/// with no host wired.
library;

import 'dart:async';
import 'dart:convert';

import '../../domain/companion_presence.dart';
import '../../domain/remote_payloads.dart';
import '../../domain/remote_usage.dart';
import '../../pairing/host_pairing_invite.dart';
import '../../protocol.dart';
import 'companion_gateway.dart';

/// A current value plus its changes. Streams emit the value on listen, then
/// every set — the seeding the gateway contract asks for.
class _Watched<T> {
  _Watched(this._value, {this.onSet});

  T _value;
  final _changes = StreamController<T>.broadcast(sync: true);

  /// Run after every set, changed or not — deduping is the caller's job.
  final void Function()? onSet;

  T get value => _value;

  set value(T next) {
    _value = next;
    _changes.add(next);
    onSet?.call();
  }

  Stream<T> get stream async* {
    yield _value;
    yield* _changes.stream;
  }
}

/// The id a scripted pairing that named no host gets. Host ids are 16 bytes of
/// hex on the wire, so the scripted ones are too — [DeviceId.parse] insists.
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

/// The scripted gateway. Constructed unpaired by default — the first-run
/// experience; [FakeCompanionGateway.paired] gives a phone already talking to a
/// host, and the mutators drive the UI from a test.
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
    DateTime? linkSince,
    DateTime Function()? now,
  }) : _now = now ?? (() => DateTime.now().toUtc()),
       _pairing = _Watched(pairing),
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
                     route: pairing.route,
                     directEndpoint: pairing.directEndpoint,
                   ),
                 ],
         ),
       ) {
    // Seeded, not observed: the fake's starting state is a fixture, so it
    // stamps only what a test moves it to — unless the test supplies one.
    _link = _Watched(link, onSet: _stampLink);
    _stampedLink = link;
    _linkSince = _Watched(linkSince);
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
    DateTime? linkSince,
    DateTime Function()? now,
    HostRoute? route,
    String? directEndpoint,
  }) => FakeCompanionGateway(
    pairing: CompanionPairing(
      capabilities: capabilities ?? CapabilitySet.all,
      hostName: hostName,
      route: route,
      directEndpoint: directEndpoint,
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
    linkSince: linkSince,
    now: now,
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
  late final _Watched<CompanionLinkState> _link;
  final _Watched<CompanionLinkPath?> _linkPath;

  /// When [_link] last changed, and the state that stamp was written for — a
  /// repeated identical report is not a change (§19).
  late final _Watched<DateTime?> _linkSince;
  CompanionLinkState? _stampedLink;
  final DateTime Function() _now;

  void _stampLink() {
    if (_link.value == _stampedLink) return;
    _stampedLink = _link.value;
    _linkSince.value = _now();
  }

  final _Watched<List<CompanionSessionSummary>> _sessions;
  final _Watched<List<CompanionConnection>> _connections;
  final Map<String, List<CompanionSessionSummary>> _sessionsByHost;
  final _transcripts = <String, _Watched<List<CompanionChatMessage>>>{};
  final _approvals = <String, _Watched<CompanionApproval?>>{};

  /// What each session is scripted to be doing. Unset means unknown — a phone
  /// that has heard nothing has not heard "nothing".
  final _activity = <String, _Watched<CompanionActivity>>{};
  final _attention = StreamController<CompanionAttentionEvent>.broadcast(
    sync: true,
  );
  final _approvalResolutions =
      StreamController<CompanionApprovalResolution>.broadcast(sync: true);

  /// Every prompt the UI sent, in order.
  final sentPrompts = <({String sessionId, String text})>[];

  /// The file each prompt carried, in step with [sentPrompts].
  final sentAttachments = <CompanionOutgoingAttachment?>[];

  /// Every send the UI *attempted*, with its idempotency key — recorded before
  /// the link check, so a refused attempt is on the list too.
  final promptAttempts = <({String? requestId, String text})>[];

  /// When set, a prompt is refused with it after being recorded.
  GatewayException? promptFailure;

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

  /// Every presence this companion reported, in order. A *call*, not a frame:
  /// the real gateway drops one that says nothing new.
  final presenceReports = <CompanionPresence>[];

  /// Every host id the UI asked to switch to, in order.
  final switchRequests = <String>[];

  /// Every [setRoutePin], in order, as (host id, pin).
  final routePinRequests = <(String, CompanionRoutePin)>[];

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

  @override
  DateTime? get linkSince => _linkSince.value;

  @override
  Stream<DateTime?> get linkSinceStates => _linkSince.stream;

  /// Settable and watched: on a real phone the reason arrives on its own, with
  /// no link-state change under it for a surface to rebuild on.
  @override
  String? get linkTrouble => _trouble.value;

  set linkTrouble(String? trouble) => _trouble.value = trouble;

  @override
  Stream<String?> get linkTroubleStates => _trouble.stream;

  final _trouble = _Watched<String?>(null);

  /// The fake has no relay of its own; the screens that read this simply
  /// render the path without naming one.
  @override
  Uri? get activeRelay => null;

  @override
  CapabilitySet get capabilities =>
      _pairing.value?.capabilities ?? CapabilitySet.none;

  @override
  Future<CompanionPairing> pairWithQr(String qrPayload) async {
    if (HostPairingInvite.looksLike(qrPayload)) return _pairInvite(qrPayload);
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
          'That is not a Karmashala pairing code. Show the QR code from the '
          "desktop's Remote access settings and scan it again.",
        ),
      );
    }
    return _pairStaged();
  }

  /// The real gateway's refusals, word for word, and a box that always
  /// answers on the route its invite names.
  Future<CompanionPairing> _pairInvite(String text) async {
    final HostPairingInvite invite;
    try {
      invite = HostPairingInvite.decode(text, now: _now());
    } on HostInviteExpiredException catch (error) {
      throw _refuse(PairingException(error.message));
    } on HostInviteTooNewException {
      throw _refuse(
        const PairingException(
          'This code was made by a newer Karmashala. Update this app, then '
          'scan it again.',
        ),
      );
    } on ProtocolException {
      throw _refuse(
        const PairingException(
          'That is not a Karmashala pairing code. Show the QR code from the '
          "desktop's Remote access settings and scan it again.",
        ),
      );
    }
    final direct = invite.route == HostRoute.direct;
    return _pairStaged(
      hostName: invite.hostName,
      searching: direct ? 'at ${invite.endpoint}' : 'over the relay',
      route: invite.route,
      directEndpoint: direct ? invite.endpoint : null,
    );
  }

  @override
  Future<CompanionPairing> pairWithCode(String shortCode, {String? at}) async {
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

  Future<CompanionPairing> _pairStaged({
    String hostName = 'Desktop',
    String searching = 'on this network and over the relay',
    HostRoute? route,
    String? directEndpoint,
  }) async {
    _emit(CompanionPairingStage.codeAccepted);
    await _gap();
    _emit(CompanionPairingStage.searching, detail: searching);
    await _gap();
    _emit(
      CompanionPairingStage.proving,
      hostName: hostName,
      capabilities: _grantOnPair,
    );
    await _gap();
    final paired = _pair(
      hostName: hostName,
      route: route,
      directEndpoint: directEndpoint,
    );
    _emit(
      CompanionPairingStage.paired,
      hostName: hostName,
      capabilities: paired.capabilities,
    );
    return paired;
  }

  CompanionPairing _pair({
    String hostName = 'Desktop',
    HostRoute? route,
    String? directEndpoint,
  }) {
    // Pairing ADDS a desktop and switches to it; only re-pairing the same
    // host replaces its record.
    final hostId = fakeHostId(_connections.value.length);
    final paired = CompanionPairing(
      capabilities: _grantOnPair,
      hostName: hostName,
      hostId: DeviceId.parse(hostId),
      route: route,
      directEndpoint: directEndpoint,
    );
    _pairing.value = paired;
    _connections.value = List.unmodifiable([
      for (final c in _connections.value) c.copyWith(active: false),
      CompanionConnection(
        hostId: hostId,
        name: hostName,
        active: true,
        route: route,
        directEndpoint: directEndpoint,
      ),
    ]);
    _linkPath.value = route == HostRoute.direct
        ? CompanionLinkPath.lan
        : _linkPath.value;
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
    for (final activity in _activity.values) {
      activity.value = CompanionActivity.unknown;
    }
    _activity.clear();
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
    final wasActive = _connections.value.any(
      (c) => c.hostId == hostId && c.active,
    );
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

  @override
  Future<void> setRoutePin(String hostId, CompanionRoutePin pin) async {
    final target = _connections.value
        .where((c) => c.hostId == hostId)
        .firstOrNull;
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
    routePinRequests.add((hostId, pin));
    _connections.value = List.unmodifiable([
      for (final c in _connections.value)
        c.hostId == hostId ? c.copyWith(pin: pin) : c,
    ]);
  }

  void _setActive(String hostId) => _connections.value = List.unmodifiable([
    for (final c in _connections.value) c.copyWith(active: c.hostId == hostId),
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
  Future<void> reportVisibility(CompanionVisibility visibility) async {
    _presence = _presence.copyWith(visibility: visibility);
    presenceReports.add(_presence);
  }

  @override
  Future<void> reportFocusedSession(String? sessionId) async {
    _presence = _presence.copyWith(
      focusedSessionId: sessionId,
      clearFocusedSession: sessionId == null,
    );
    presenceReports.add(_presence);
  }

  CompanionPresence _presence = CompanionPresence.unknown;

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

  /// Sessions whose transcript request fails, and with what — the host
  /// refusing for want of a capability, or a link that dropped mid-request.
  final Map<String, Object> transcriptFailures = {};

  /// Sessions whose transcript never answers at all: the shape of a request
  /// sent into a rendezvous nobody was at.
  final Set<String> stalledTranscripts = {};

  @override
  Stream<List<CompanionChatMessage>> transcript(String sessionId) {
    final failure = transcriptFailures[sessionId];
    if (failure != null) {
      return Stream<List<CompanionChatMessage>>.error(failure);
    }
    // Never emits and never closes: a screen must still find something to
    // say, because a user cannot tell "slow" from "never" by looking.
    if (stalledTranscripts.contains(sessionId)) {
      return Stream<List<CompanionChatMessage>>.multi((_) {});
    }
    return _transcriptOf(sessionId).stream;
  }

  @override
  Stream<CompanionApproval?> pendingApproval(String sessionId) =>
      _approvalOf(sessionId).stream;

  @override
  Stream<CompanionActivity> activity(String sessionId) =>
      _activityOf(sessionId).stream;

  /// Scripts what one session is doing, as a host frame would.
  void setActivity(String sessionId, CompanionActivity activity) =>
      _activityOf(sessionId).value = activity;

  /// What `workspace.list` answers with. Settable so a test can script a
  /// desktop with several projects, or with none.
  List<RemoteWorkspaceProject> workspace = const [];

  /// Every start the UI asked for, in order — including the retries, so a test
  /// can see the idempotency key the screen actually resent.
  final startedSessions =
      <
        ({
          String requestId,
          String repositoryId,
          String installationId,
          String permissionMode,
          String? title,
          String? message,
        })
      >[];

  /// When set, every start throws it instead of answering.
  GatewayException? startFailure;

  /// The sessions this fake has already handed back, by idempotency key — the
  /// host's ledger, so a scripted retry behaves the way the real one does.
  final Map<String, RemoteSessionStarted> _startsByKey = {};

  @override
  Future<List<RemoteWorkspaceProject>> listWorkspace() async {
    _requireLink();
    return List.unmodifiable(workspace);
  }

  @override
  Future<List<RemoteWorkspaceProject>> listProjects() async => const [];

  @override
  Future<RemoteWorkspaceProject> addProject({
    required String requestId,
    required String name,
    required String path,
  }) async =>
      RemoteWorkspaceProject(projectId: requestId, name: name, path: path);

  @override
  Future<RemoteSessionStarted> startSession({
    required String requestId,
    required String repositoryId,
    required String installationId,
    required String permissionMode,
    String? title,
    String? message,
  }) async {
    _requireLink();
    startedSessions.add((
      requestId: requestId,
      repositoryId: repositoryId,
      installationId: installationId,
      permissionMode: permissionMode,
      title: title,
      message: message,
    ));
    final failure = startFailure;
    if (failure != null) throw failure;
    final remembered = _startsByKey[requestId];
    if (remembered != null) {
      return RemoteSessionStarted(
        sessionId: remembered.sessionId,
        title: remembered.title,
        permissionMode: remembered.permissionMode,
        replayed: true,
      );
    }
    final started = RemoteSessionStarted(
      sessionId: 'started-${_startsByKey.length + 1}',
      title: title ?? 'Session',
      permissionMode: permissionMode,
    );
    _startsByKey[requestId] = started;
    setSessions([
      ..._sessions.value,
      CompanionSessionSummary(
        id: started.sessionId,
        title: started.title,
        agentLabel: 'Agent  ·  running',
        projectName: 'Demo',
        status: CompanionSessionStatus.working,
      ),
    ]);
    return started;
  }

  @override
  Future<RemoteSessionStarted> resumeSession({
    required String requestId,
    required String sessionId,
  }) async {
    _requireLink();
    resumedSessions.add((requestId: requestId, sessionId: sessionId));
    final failure = resumeFailure;
    if (failure != null) throw failure;
    return _resumesByKey.putIfAbsent(
      requestId,
      () => RemoteSessionStarted(
        sessionId: 'resumed-$sessionId',
        title: 'Resumed',
      ),
    );
  }

  final resumedSessions = <({String requestId, String sessionId})>[];
  GatewayException? resumeFailure;
  final _resumesByKey = <String, RemoteSessionStarted>{};

  @override
  Future<RemotePromptDelivery> sendPrompt(
    String sessionId,
    String text, {
    CompanionOutgoingAttachment? attachment,
    void Function(int sent, int total)? onProgress,
    String? requestId,
  }) async {
    promptAttempts.add((requestId: requestId, text: text));
    _requireLink();
    final failure = promptFailure;
    if (failure != null) throw failure;
    sentPrompts.add((sessionId: sessionId, text: text));
    sentAttachments.add(attachment);
    if (attachment != null) {
      // The slice count the real gateway would report, so a widget test can
      // watch the progress line without a link.
      final total = (attachment.bytes.length / kAttachmentChunkBytes).ceil();
      for (var sent = 0; sent <= total; sent++) {
        onProgress?.call(sent, total);
      }
      // A prompt carrying a file is left in the desktop's own message box, so
      // nothing is appended to the transcript here.
      return RemotePromptDelivery.offered;
    }
    appendMessage(sessionId, CompanionChatMessage(role: 'user', text: text));
    return RemotePromptDelivery.sent;
  }

  @override
  Future<void> answerQuestion(
    String sessionId,
    String approvalId, {
    List<RemoteQuestionAnswer> answers = const [],
    bool decline = false,
  }) async {
    _requireLink();
    final pending = _approvalOf(sessionId);
    if (pending.value?.id != approvalId || pending.value?.question == null) {
      throw const GatewayException(
        'That question is no longer waiting for an answer.',
      );
    }
    answeredQuestions.add((
      sessionId: sessionId,
      approvalId: approvalId,
      answers: answers,
      decline: decline,
    ));
    pending.value = null;
    _approvalResolutions.add(
      CompanionApprovalResolution(
        sessionId: sessionId,
        outcome: decline
            ? CompanionApprovalOutcome.denied
            : CompanionApprovalOutcome.answered,
      ),
    );
  }

  /// Every [answerQuestion], in order.
  final answeredQuestions =
      <
        ({
          String sessionId,
          String approvalId,
          List<RemoteQuestionAnswer> answers,
          bool decline,
        })
      >[];

  @override
  Future<void> answerMenu(
    String sessionId,
    String approvalId,
    int option,
  ) async {
    _requireLink();
    final pending = _approvalOf(sessionId);
    if (pending.value?.id != approvalId || pending.value?.menu == null) {
      throw const GatewayException(
        'That prompt is no longer waiting for an answer.',
      );
    }
    answeredMenus.add((
      sessionId: sessionId,
      approvalId: approvalId,
      option: option,
    ));
    pending.value = null;
    _approvalResolutions.add(
      CompanionApprovalResolution(
        sessionId: sessionId,
        outcome: CompanionApprovalOutcome.answered,
      ),
    );
  }

  /// What [usage] answers; set by a test.
  RemoteUsageSnapshot usageSnapshot = RemoteUsageSnapshot(
    accounts: const [],
    observedAt: DateTime.utc(2026),
  );

  /// When set, [usage] throws it — a refusal in the host's words.
  GatewayException? usageFailure;

  /// How many times [usage] was asked.
  int usageReads = 0;

  @override
  Future<RemoteUsageSnapshot> usage() async {
    _requireLink();
    usageReads++;
    final failure = usageFailure;
    if (failure != null) throw failure;
    if (!capabilities.has(Capability.viewUsage)) {
      throw const GatewayException('this device was not granted view_usage');
    }
    return usageSnapshot;
  }

  /// Every [answerMenu], in order.
  final answeredMenus = <({String sessionId, String approvalId, int option})>[];

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
    final pending = _approvalOf(sessionId);
    if (pending.value != null) {
      pending.value = null;
      _approvalResolutions.add(
        CompanionApprovalResolution(
          sessionId: sessionId,
          outcome: decision == CompanionApprovalDecision.approve
              ? CompanionApprovalOutcome.approved
              : CompanionApprovalOutcome.denied,
        ),
      );
    }
  }

  @override
  Stream<CompanionApprovalResolution> get approvalResolutions =>
      _approvalResolutions.stream;

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

  _Watched<CompanionActivity> _activityOf(String sessionId) =>
      _activity[sessionId] ??= _Watched(CompanionActivity.unknown);

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

  /// The host answering it somewhere else: the card goes, and says why.
  void resolveApproval(
    String sessionId, {
    CompanionApprovalOutcome outcome = CompanionApprovalOutcome.elsewhere,
  }) {
    final pending = _approvalOf(sessionId);
    if (pending.value == null) return;
    pending.value = null;
    _approvalResolutions.add(
      CompanionApprovalResolution(sessionId: sessionId, outcome: outcome),
    );
  }

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
              CompanionAttentionKind.finished ||
              CompanionAttentionKind.usageLimit => CompanionSessionStatus.idle,
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
