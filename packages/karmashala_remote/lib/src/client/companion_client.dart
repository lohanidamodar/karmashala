/// The companion's session-API client: connect over relay or LAN, typed
/// requests with correlation ids, typed events.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../domain/companion_presence.dart';
import '../domain/remote_payloads.dart';
import '../domain/remote_session_options.dart';
import '../domain/remote_notes.dart';
import '../domain/remote_usage.dart';
import '../pairing/pairing_wire.dart';
import '../protocol.dart';
import '../transport/key_schedule.dart';
import '../transport/link_liveness.dart';
import '../transport/relay_transport.dart';
import '../transport/remote_transport.dart';
import '../transport/sealed_channel.dart';
import '../transport/stream_flow.dart';
import 'companion_store.dart';
import 'relay_dial.dart';

export 'relay_dial.dart';

/// Request ids of `link.ping`, disjoint from [CompanionClient]'s `q` ids.
const String _kPingIdPrefix = 'lp';

/// The host refused a request, or never answered.
class RemoteApiException implements Exception {
  const RemoteApiException(
    this.message, {
    this.code,
    this.hostAbsent = false,
    this.relayUnreachable = false,
  });

  final String message;

  /// The protocol error code, when the host sent one.
  final ErrorCode? code;

  /// True when the failure is "nobody was at the rendezvous": the relay took
  /// the socket and no host ever answered the hello.
  final bool hostAbsent;

  /// True when the relay itself never took the socket — the desktop may be
  /// perfectly awake, and the phone must not send its owner to check it.
  final bool relayUnreachable;

  @override
  String toString() => 'RemoteApiException(${code?.wire}: $message)';
}

/// Typed events from the host.
sealed class CompanionEvent {
  const CompanionEvent();
}

class SessionChangedEvent extends CompanionEvent {
  const SessionChangedEvent(this.snapshot, {this.raw});
  final RemoteSessionSnapshot snapshot;

  /// The event's payload as it arrived, so a caller can read row fields a
  /// newer host sends that this build's snapshot type has no name for yet.
  final Map<String, Object?>? raw;
}

class TranscriptAppendedEvent extends CompanionEvent {
  const TranscriptAppendedEvent(this.page);
  final RemoteTranscriptPage page;
}

/// What one session is doing right now — see [FrameType.sessionActivity].
class SessionActivityEvent extends CompanionEvent {
  const SessionActivityEvent(this.activity);
  final RemoteSessionActivity activity;
}

class ApprovalRequestedEvent extends CompanionEvent {
  const ApprovalRequestedEvent(this.request);
  final RemoteApprovalRequest request;
}

/// The approval for a session stopped waiting — see [FrameType.approvalResolved].
class ApprovalResolvedEvent extends CompanionEvent {
  const ApprovalResolvedEvent(this.resolution);
  final RemoteApprovalResolved resolution;
}

class HostStatusEvent extends CompanionEvent {
  const HostStatusEvent(this.status);
  final RemoteHostStatus status;
}

/// The host revoked this pairing. The link is over, and said so.
class PairingRevokedEvent extends CompanionEvent {
  const PairingRevokedEvent();
}

/// Nothing arrived from the host for [silence], pings included: the link is
/// dead even though no socket said so.
class LinkSilentEvent extends CompanionEvent {
  const LinkSilentEvent(this.silence);
  final Duration silence;
}

/// One connection to the paired host.
class CompanionClient {
  CompanionClient({
    required CompanionPairing pairing,
    required this.store,
    RelayTransportFactoryFn? relayFactory,
    this.requestTimeout = const Duration(seconds: 15),
    this.storeTimeout = const Duration(seconds: 5),
    this.onLog,
    this.watching,
    this.linkPingAfter = kLinkPingAfter,
    this.linkDeadAfter = kLinkDeadAfter,
    // ignore: prefer_initializing_formals — mutable field, named for callers.
  }) : _pairing = pairing,
       _relayFactory = relayFactory ?? _defaultRelayFactory;

  static RemoteTransport _defaultRelayFactory(
    Uri relay,
    RendezvousId rendezvous,
  ) => RelayTransport.connect(relay: relay, rendezvous: rendezvous);

  final CompanionStore store;
  final Duration requestTimeout;

  /// The longest a write to the phone's keystore may hold up a connection.
  final Duration storeTimeout;

  final void Function(String message)? onLog;
  final RelayTransportFactoryFn _relayFactory;

  /// Whether the owner is looking at the app: true, false, or null for
  /// nothing said. Read at every ack, so it is never stale on the wire.
  final bool? Function()? watching;

  /// Inbound silence before a `link.ping`, and before the link is dead.
  final Duration linkPingAfter;
  final Duration linkDeadAfter;

  LinkLiveness? _liveness;
  int _nextPingId = 0;

  CompanionPairing _pairing;

  CompanionPairing get pairing => _pairing;

  RemoteTransport? _transport;
  bool _ownsTransport = false;
  StreamSubscription<Uint8List>? _subscription;
  SealedChannel? _channel;
  int _generation = 0;

  /// Set by [close], and never cleared: a closed client dials nothing more.
  bool _closed = false;

  final StreamController<CompanionEvent> _events =
      StreamController<CompanionEvent>.broadcast();
  final Map<String, Completer<Map<String, Object?>>> _pending = {};
  Completer<RemoteHostStatus>? _statusArrived;
  int _nextRequestId = 0;

  /// Serialises seals so `Envelope.seq` matches the sealed sequence.
  Future<void> _sendChain = Future<void>.value();

  /// Whether the host said it reads `stream.ack`.
  bool _acksWanted = false;
  int _ackSeq = -1;
  int _ackSentSeq = -1;
  int _ackBytes = 0;
  Timer? _ackTimer;

  /// Numbers input frames at seal time, so their order is the wire's order.
  int _nextInput = 0;
  Timer? _leaseTimer;

  /// Host events, as they arrive. Broadcast: listen any time after [connect].
  Stream<CompanionEvent> get events => _events.stream;

  bool get isConnected => _channel != null;

  /// The generation this connection runs at.
  int get generation => _generation;

  /// Connects and waits for the host's `host.status`. Without [transport] the
  /// relay is dialled at the stored counter, probing forward through
  /// [kCompanionProbeWindow] generations for a host whose counter fell behind.
  Future<RemoteHostStatus> connect({
    RemoteTransport? transport,
    int? generation,
    Duration helloTimeout = const Duration(seconds: 8),
  }) async {
    if (_closed) throw const RemoteApiException('connection closed');
    if (_transport != null) {
      throw StateError('already connected; close() first');
    }
    if (transport != null) {
      final g = generation ?? _pairing.generation;
      final status = await _attach(transport, g, false, helloTimeout);
      await _persistNextCounter(g);
      return status;
    }
    for (var probe = 0; probe < kCompanionProbeWindow; probe++) {
      final g = _pairing.generation + probe;
      final rendezvous = await rendezvousFor(_key, g);
      // Checked before every generation, not only the first: a close that
      // lands mid-walk must not be answered by the next dial.
      if (_closed) throw const RemoteApiException('connection closed');
      final dialled = _relayFactory(_pairing.relay, rendezvous);
      // Probing forward means something only once this relay has taken a
      // socket: waiting out the hello window three times over turns one
      // unreachable address into a minute of "Connecting…".
      var socketOpened = false;
      final watching = dialled.states.listen((state) {
        if (state == TransportState.connected) socketOpened = true;
      });
      try {
        final status = await _attach(dialled, g, true, helloTimeout);
        await _persistNextCounter(g);
        return status;
      } on TimeoutException {
        await _detach();
        await dialled.close();
        if (_closed) throw const RemoteApiException('connection closed');
        if (!socketOpened) {
          onLog?.call('the relay never took the socket; not probing forward');
          throw const RemoteApiException(
            'this relay could not be reached',
            relayUnreachable: true,
          );
        }
        onLog?.call('no host at generation $g; probing forward');
      } finally {
        await watching.cancel();
      }
    }
    throw const RemoteApiException(
      'the host did not answer on any rendezvous',
      hostAbsent: true,
    );
  }

  SecretKeyData get _key => SecretKeyData(_pairing.deviceKey);

  Future<RemoteHostStatus> _attach(
    RemoteTransport transport,
    int generation,
    bool owns,
    Duration helloTimeout,
  ) async {
    _transport = transport;
    _ownsTransport = owns;
    _generation = generation;
    _channel = await SealedChannel.forDevice(
      deviceKey: _key,
      role: ChannelRole.companion,
      generation: generation,
    );
    // Closed while the channel was being derived: nothing is listened to.
    if (_closed) throw const RemoteApiException('connection closed');
    final arrived = _statusArrived = Completer<RemoteHostStatus>();
    _resetAcks();
    _nextInput = 0;
    _subscription = transport.frames.listen(_onFrame);
    final rendezvous = await rendezvousFor(_key, generation);
    transport.send(LinkHello(rendezvous).encode());
    return arrived.future.timeout(helloTimeout);
  }

  /// Re-proves the host is still at the far end of a socket that came back: a
  /// relay accepts one whether or not anybody else is there. Re-sends
  /// [LinkHello] on the SAME channel, so no sequence or key schedule moves.
  /// Throws [TimeoutException] when nobody answers.
  Future<RemoteHostStatus> rehandshake({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final transport = _transport;
    if (transport == null || _channel == null) {
      throw StateError('not connected');
    }
    final arrived = _statusArrived = Completer<RemoteHostStatus>();
    final rendezvous = await rendezvousFor(_key, _generation);
    transport.send(LinkHello(rendezvous).encode());
    return arrived.future.timeout(timeout);
  }

  Future<void> _detach() async {
    _liveness?.stop();
    _liveness = null;
    _resetAcks();
    await _subscription?.cancel();
    _subscription = null;
    _transport = null;
    _channel = null;
    _statusArrived = null;
  }

  Future<void> _persistNextCounter(int usedGeneration) async {
    // Bump after a connection pairs (loop 64): the next session dials fresh.
    _pairing = _pairing.withGeneration(usedGeneration + 1);
    try {
      await _pairing.save(store).timeout(storeTimeout);
    } on Object catch (error) {
      // A counter that did not stick costs a probe forward on the next dial,
      // which is what the probe window is for. A keystore that stalls or
      // refuses must never cost the link that is already up.
      onLog?.call('could not persist the generation counter: $error');
    }
  }

  Future<void> _onFrame(Uint8List frame) async {
    final channel = _channel;
    if (channel == null) return;
    final SealedFrame opened;
    try {
      opened = await channel.unseal(frame);
    } on SealedChannelException catch (error) {
      onLog?.call('refused a frame: $error');
      return;
    }
    _liveness?.heard();
    final Envelope envelope;
    try {
      envelope = Envelope.fromBytes(opened.plaintext, accept: VersionRange.any);
    } on ProtocolException {
      return;
    }
    try {
      _dispatch(envelope);
    } finally {
      _rendered(opened.sequence, frame.length);
    }
  }

  void _dispatch(Envelope envelope) {
    // A ping's answer — `result`, or an older host's `unknown_type` — has
    // already done its job by arriving.
    if (envelope.id?.startsWith(_kPingIdPrefix) ?? false) return;
    switch (envelope.knownType) {
      case FrameType.result:
        _pending.remove(envelope.id)?.complete(envelope.payload);
      case FrameType.error:
        final code = envelope.payload['code'];
        final message = envelope.payload['message'];
        final error = RemoteApiException(
          message is String ? message : 'the host refused the request',
          code: code is String ? ErrorCode.tryParse(code) : null,
        );
        final expected = envelope.payload['expected'];
        if (error.code == ErrorCode.outOfOrder &&
            expected is int &&
            expected > _nextInput) {
          _nextInput = expected;
        }
        final pending = _pending.remove(envelope.id);
        if (pending != null) {
          pending.completeError(error);
        } else if (error.code == ErrorCode.streamStalled) {
          // Reading again is the whole answer: the ack reopens the stream and
          // the host sends where things stand now.
          onLog?.call('the host held our stream; acking to reopen it');
          _ackSentSeq = -1;
          _ackTimer ??= Timer(Duration.zero, _flushAck);
        } else {
          onLog?.call('host error: ${error.code?.wire}');
        }
      case FrameType.hostStatus:
        try {
          final status = RemoteHostStatus.fromJson(envelope.payload);
          _acksWanted = status.streamAcks;
          if (_acksWanted) {
            _leaseTimer ??= Timer.periodic(kWatchRenew, (_) {
              if (watching?.call() == true) _flushAck(force: true);
            });
          }
          if (_statusArrived?.isCompleted == false) {
            _statusArrived!.complete(status);
          }
          _startLiveness();
          _emit(HostStatusEvent(status));
        } on ProtocolException {
          return;
        }
      case FrameType.pairingRevoked:
        onLog?.call('the host revoked this pairing');
        _emit(const PairingRevokedEvent());
      case FrameType.sessionChanged:
        _tolerant(
          () => _emit(
            SessionChangedEvent(
              RemoteSessionSnapshot.fromJson(envelope.payload),
              raw: envelope.payload,
            ),
          ),
        );
      case FrameType.transcriptAppended:
        _tolerant(
          () => _emit(
            TranscriptAppendedEvent(
              RemoteTranscriptPage.fromJson(envelope.payload),
            ),
          ),
        );
      case FrameType.sessionActivity:
        _tolerant(
          () => _emit(
            SessionActivityEvent(
              RemoteSessionActivity.fromJson(envelope.payload),
            ),
          ),
        );
      case FrameType.approvalRequested:
        _tolerant(
          () => _emit(
            ApprovalRequestedEvent(
              RemoteApprovalRequest.fromJson(envelope.payload),
            ),
          ),
        );
      case FrameType.approvalResolved:
        _tolerant(
          () => _emit(
            ApprovalResolvedEvent(
              RemoteApprovalResolved.fromJson(envelope.payload),
            ),
          ),
        );
      default:
        // A frame from a newer host; nothing to do with it here.
        onLog?.call('ignored a frame of type ${envelope.type}');
    }
  }

  /// Coalesced: one ack per [kStreamAckBytes] or [kStreamAckDelay], so a
  /// cellular phone does not pay a round trip per frame.
  void _rendered(int seq, int bytes) {
    if (!_acksWanted || _closed) return;
    if (seq > _ackSeq) _ackSeq = seq;
    _ackBytes += bytes;
    if (_ackBytes >= kStreamAckBytes) {
      _flushAck();
    } else {
      _ackTimer ??= Timer(kStreamAckDelay, _flushAck);
    }
  }

  /// Keyed on inbound silence, not outbound: acks and lease renewals go out
  /// unanswered, so a watching phone is never silent outbound on a dead link.
  void _startLiveness() {
    if (_closed || _channel == null) return;
    (_liveness ??= LinkLiveness(
      pingAfter: linkPingAfter,
      deadAfter: linkDeadAfter,
      onPing: _sendPing,
      onDead: (silence) {
        onLog?.call(
          'nothing from the host in ${silence.inSeconds}s; the link is dead',
        );
        _emit(LinkSilentEvent(silence));
      },
    )).start();
  }

  void _sendPing() {
    final channel = _channel;
    final transport = _transport;
    if (channel == null || transport == null) return;
    final id = '$_kPingIdPrefix${_nextPingId++}';
    _sendChain = _sendChain
        .then((_) async {
          final envelope = Envelope.of(
            FrameType.linkPing,
            seq: channel.nextSendSequence,
            id: id,
          );
          transport.send(await channel.seal(envelope.toBytes()));
        })
        .catchError((Object error) {
          // The deadline, not this send, decides whether the link is dead.
          onLog?.call('a ping did not go out: $error');
        });
  }

  /// Says at once that the owner started or stopped looking, rather than at
  /// the next frame or renewal.
  void presenceChanged() {
    if (_acksWanted) _flushAck(force: true);
  }

  void _flushAck({bool force = false}) {
    _ackTimer?.cancel();
    _ackTimer = null;
    final channel = _channel;
    final transport = _transport;
    if (channel == null || transport == null || _ackSeq < 0) return;
    if (_ackSeq == _ackSentSeq && !force) return;
    final seq = _ackSentSeq = _ackSeq;
    final looking = watching?.call();
    _ackBytes = 0;
    _sendChain = _sendChain
        .then((_) async {
          final envelope = Envelope.of(
            FrameType.streamAck,
            seq: channel.nextSendSequence,
            payload: {'seq': seq, 'watching': ?looking},
          );
          transport.send(await channel.seal(envelope.toBytes()));
        })
        .catchError((Object error) {
          // A lost ack is repaired by the next one; the host waits, not drops.
          onLog?.call('an ack did not go out: $error');
        });
  }

  void _resetAcks() {
    _ackTimer?.cancel();
    _ackTimer = null;
    _leaseTimer?.cancel();
    _leaseTimer = null;
    _acksWanted = false;
    _ackSeq = -1;
    _ackSentSeq = -1;
    _ackBytes = 0;
  }

  void _tolerant(void Function() parse) {
    try {
      parse();
    } on ProtocolException catch (error) {
      onLog?.call('ignored a malformed event: $error');
    }
  }

  void _emit(CompanionEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  // --- Typed requests --------------------------------------------------------

  Future<List<RemoteSessionSnapshot>> listSessions() async => [
    for (final row in await listSessionRows()) row.snapshot,
  ];

  /// [listSessions], keeping each row's raw JSON beside the parsed snapshot —
  /// for row fields a newer host sends that this build has no name for yet.
  Future<List<({RemoteSessionSnapshot snapshot, Map<String, Object?> json})>>
  listSessionRows() async {
    final payload = await _request(FrameType.sessionsList, const {});
    final sessions = payload['sessions'];
    return [
      if (sessions is List)
        for (final entry in sessions)
          if (entry is Map<String, Object?>)
            (snapshot: RemoteSessionSnapshot.fromJson(entry), json: entry),
    ];
  }

  Future<void> subscribeSession(String sessionId) async {
    await _request(FrameType.sessionSubscribe, {'sessionId': sessionId});
  }

  Future<void> unsubscribeSession(String sessionId) async {
    await _request(FrameType.sessionUnsubscribe, {'sessionId': sessionId});
  }

  Future<RemoteTranscriptPage> transcript(
    String sessionId, {
    int after = 0,
  }) async {
    final payload = await _request(FrameType.transcriptGet, {
      'sessionId': sessionId,
      'after': after,
    });
    return RemoteTranscriptPage.fromJson(payload);
  }

  /// Asks outright what one session is doing right now — for opening a session
  /// and for coming back from a reconnect, where the unsolicited frames it
  /// missed cannot be replayed. Refused in words without `view_activity`.
  Future<RemoteSessionActivity> activity(String sessionId) async {
    final payload = await _request(FrameType.sessionActivity, {
      'sessionId': sessionId,
    });
    return RemoteSessionActivity.fromJson(payload);
  }

  /// Sends a prompt, optionally quoting an upload this link completed, and
  /// answers what became of it. An older host answers neither, which reads as
  /// [RemotePromptDelivery.sent]. [requestId] is the idempotency key: the SAME
  /// value for a retry of a send nobody answered, so a newer host types it once.
  Future<RemotePromptDelivery> sendPrompt(
    String sessionId,
    String text, {
    String? attachmentId,
    String? requestId,
  }) async {
    final payload = await _request(FrameType.promptSend, {
      'sessionId': sessionId,
      'text': text,
      'attachment': ?attachmentId,
      'requestId': ?requestId,
    });
    return RemotePromptDelivery.parse(payload['delivery']);
  }

  /// Asks to send a file, **before any of it crosses**, so a refusal costs one
  /// small frame. Refused in words without `send_attachment`.
  Future<RemoteAttachmentOffer> beginAttachment(
    RemoteAttachmentBegin request,
  ) async => RemoteAttachmentOffer.fromJson(
    await _request(FrameType.attachmentBegin, request.toJson()),
  );

  /// Hands over one slice, and waits for the host to say it landed. Awaited on
  /// purpose: the outbound queue drops its **oldest** frame under pressure.
  Future<void> sendAttachmentChunk(
    String uploadId,
    int seq,
    List<int> data,
  ) async {
    await _request(FrameType.attachmentChunk, {
      'uploadId': uploadId,
      'seq': seq,
      'data': base64Encode(data),
    });
  }

  /// Answers a pending approval; returns the label of the key the host
  /// pressed, in the agent's own words. [optionId] chooses one of the agent's
  /// own options; [approve] is what it means, which an older host answers.
  Future<String> answerApproval(
    String sessionId, {
    required bool approve,
    String? approvalId,
    String? optionId,
  }) async {
    final payload = await _request(FrameType.approvalAnswer, {
      'sessionId': sessionId,
      'decision': approve ? 'approve' : 'deny',
      'approvalId': ?approvalId,
      'optionId': ?optionId,
    });
    final pressed = payload['pressed'];
    return pressed is String ? pressed : '';
  }

  /// `question.answer` — answers or declines the question [request] names.
  Future<String> answerQuestion(RemoteQuestionAnswerRequest request) async {
    final payload = await _request(FrameType.questionAnswer, request.toJson());
    final done = payload['done'];
    return done is String ? done : '';
  }

  /// `session.options` — what [sessionId] can be put on, and what it is on.
  Future<RemoteSessionOptions> sessionOptions(String sessionId) async =>
      RemoteSessionOptions.fromJson(
        await _request(FrameType.sessionOptions, {'sessionId': sessionId}),
      );

  /// `session.configure` — puts [sessionId] on a model and/or permission mode.
  /// A field left out is left alone; `followDefault` on it hands it back to
  /// the desktop's default.
  Future<RemoteConfigureOutcome> configureSession(
    String sessionId, {
    String? modelId,
    bool modelFollowsDefault = false,
    String? permissionId,
    bool permissionFollowsDefault = false,
  }) async {
    final payload = await _request(FrameType.sessionConfigure, {
      'sessionId': sessionId,
      if (modelId != null || modelFollowsDefault) 'model': modelId,
      if (permissionId != null || permissionFollowsDefault)
        'permission': permissionId,
    });
    return RemoteConfigureOutcome.parse(payload['outcome']);
  }

  /// `usage.get` — every agent account's usage limits.
  Future<RemoteUsageSnapshot> usage() async => RemoteUsageSnapshot.fromJson(
    await _request(FrameType.usageGet, const {}),
  );

  /// `notes.get` — the desktop's notes and todo list.
  Future<RemoteNotesSnapshot> notes() async => RemoteNotesSnapshot.fromJson(
    await _request(FrameType.notesGet, const {}),
  );

  /// `menu.answer` — chooses one option of the menu [request] names; answers
  /// with the option's words.
  Future<String> answerMenu(RemoteMenuAnswerRequest request) async {
    final payload = await _request(FrameType.menuAnswer, request.toJson());
    final chosen = payload['chosen'];
    return chosen is String ? chosen : '';
  }

  /// `workspace.list` — the projects, checkouts and installed agents a session
  /// could be started in. A row this build cannot parse is dropped.
  Future<List<RemoteWorkspaceProject>> listWorkspace() async {
    final payload = await _request(FrameType.workspaceList, const {});
    final projects = payload['projects'];
    return [
      if (projects is List)
        for (final entry in projects)
          if (entry is Map<String, Object?>)
            RemoteWorkspaceProject.fromJson(entry),
    ];
  }

  Future<List<RemoteWorkspaceProject>> listProjects() async {
    final payload = await _request(FrameType.projectsList, const {});
    final projects = payload['projects'];
    return [
      if (projects is List)
        for (final entry in projects)
          if (entry is Map<String, Object?>)
            RemoteWorkspaceProject.fromJson(entry),
    ];
  }

  Future<RemoteWorkspaceProject> addProject({
    required String requestId,
    required String name,
    required String path,
  }) async {
    final payload = await _request(FrameType.projectAdd, {
      'requestId': requestId,
      'name': name,
      'path': path,
    });
    return RemoteWorkspaceProject.fromJson(payload);
  }

  /// `session.start`. [requestId] is the idempotency key: the SAME value for a
  /// retry of the same intention, a fresh one the moment the user changes what
  /// they are asking for.
  Future<RemoteSessionStarted> startSession({
    required String requestId,
    required String repositoryId,
    required String installationId,
    required String permissionMode,
    String? title,
    String? message,
    bool worktree = false,
  }) async {
    final payload = await _request(FrameType.sessionStart, {
      'requestId': requestId,
      'repositoryId': repositoryId,
      'installationId': installationId,
      'permissionMode': permissionMode,
      'title': ?title,
      'message': ?message,
      if (worktree) 'worktree': true,
    });
    return RemoteSessionStarted.fromJson(payload);
  }

  Future<RemoteSessionStarted> resumeSession({
    required String requestId,
    required String sessionId,
  }) async {
    final payload = await _request(FrameType.sessionResume, {
      'requestId': requestId,
      'sessionId': sessionId,
    });
    return RemoteSessionStarted.fromJson(payload);
  }

  /// Registers for notifications, and says what this companion is doing. The
  /// presence fields are **additive**: a host that predates them reads `token`
  /// and `platform` and never looks at the rest.
  Future<void> registerNotifications({
    required String token,
    required String platform,
    CompanionPresence presence = CompanionPresence.unknown,
  }) async {
    await _request(FrameType.notificationsRegister, {
      'token': token,
      'platform': platform,
      ...presence.toRegisterFields(),
    });
  }

  Future<Map<String, Object?>> _request(
    FrameType type,
    Map<String, Object?> payload,
  ) async {
    final channel = _channel;
    final transport = _transport;
    if (channel == null || transport == null) {
      throw StateError('not connected');
    }
    final id = 'q${_nextRequestId++}';
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    final sent = _sendChain.then((_) async {
      final envelope = Envelope.of(
        type,
        seq: channel.nextSendSequence,
        id: id,
        payload: type.isInput
            ? {...payload, 'inputSeq': _nextInput++}
            : payload,
      );
      transport.send(await channel.seal(envelope.toBytes()));
    });
    // The chain carries on past a failed send; only this request fails.
    _sendChain = sent.catchError((Object _) {});
    try {
      await sent;
    } on Object {
      _pending.remove(id);
      rethrow;
    }
    try {
      return await completer.future.timeout(requestTimeout);
    } on TimeoutException {
      _pending.remove(id);
      throw const RemoteApiException('the host did not answer');
    }
  }

  Future<void> close() async {
    _closed = true;
    // The hello in flight ends now, not at its timeout — which connect would
    // have read as "no host at this generation" and answered with a dial.
    final arrived = _statusArrived;
    if (arrived != null && !arrived.isCompleted) {
      arrived.completeError(const RemoteApiException('connection closed'));
      // A hello whose send threw was never awaited; its failure is nobody's.
      arrived.future.ignore();
    }
    final transport = _transport;
    await _detach();
    if (_ownsTransport && transport != null) await transport.close();
    for (final pending in _pending.values) {
      pending.completeError(const RemoteApiException('connection closed'));
      pending.future.ignore();
    }
    _pending.clear();
    await _events.close();
  }
}
