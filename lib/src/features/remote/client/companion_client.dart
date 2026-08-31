/// The companion's session-API client: connect over relay or LAN, typed
/// requests with correlation ids, typed events. Pure Dart — the phone UI
/// (another loop) renders what this returns; tests drive it over loopback.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../domain/remote_payloads.dart';
import '../pairing/pairing_wire.dart';
import '../protocol.dart';
import '../transport/key_schedule.dart';
import '../transport/relay_transport.dart';
import '../transport/remote_transport.dart';
import '../transport/sealed_channel.dart';
import 'companion_store.dart';

/// How many generations forward the companion probes when its counter and the
/// host's have drifted. Must stay within the host's own listen window.
const int kCompanionProbeWindow = 3;

/// The host refused a request, or never answered.
class RemoteApiException implements Exception {
  const RemoteApiException(this.message, {this.code, this.hostAbsent = false});

  final String message;

  /// The protocol error code, when the host sent one.
  final ErrorCode? code;

  /// True when the failure is "nobody was at the rendezvous": the relay took
  /// the socket and no host ever answered the hello. A different fact from a
  /// refusal or a broken network, and the phone says so.
  final bool hostAbsent;

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

class ApprovalRequestedEvent extends CompanionEvent {
  const ApprovalRequestedEvent(this.request);
  final RemoteApprovalRequest request;
}

class HostStatusEvent extends CompanionEvent {
  const HostStatusEvent(this.status);
  final RemoteHostStatus status;
}

/// One connection to the paired host.
class CompanionClient {
  CompanionClient({
    required CompanionPairing pairing,
    required this.store,
    RelayTransportFactoryFn? relayFactory,
    this.requestTimeout = const Duration(seconds: 15),
    this.onLog,
    // ignore: prefer_initializing_formals — mutable field, named for callers.
  }) : _pairing = pairing,
       _relayFactory = relayFactory ?? _defaultRelayFactory;

  static RemoteTransport _defaultRelayFactory(
    Uri relay,
    RendezvousId rendezvous,
  ) => RelayTransport.connect(relay: relay, rendezvous: rendezvous);

  final CompanionStore store;
  final Duration requestTimeout;
  final void Function(String message)? onLog;
  final RelayTransportFactoryFn _relayFactory;

  CompanionPairing _pairing;

  CompanionPairing get pairing => _pairing;

  RemoteTransport? _transport;
  bool _ownsTransport = false;
  StreamSubscription<Uint8List>? _subscription;
  SealedChannel? _channel;
  int _generation = 0;

  final StreamController<CompanionEvent> _events =
      StreamController<CompanionEvent>.broadcast();
  final Map<String, Completer<Map<String, Object?>>> _pending = {};
  Completer<RemoteHostStatus>? _statusArrived;
  int _nextRequestId = 0;

  /// Serialises seals so `Envelope.seq` matches the sealed sequence.
  Future<void> _sendChain = Future<void>.value();

  /// Host events, as they arrive. Broadcast: listen any time after [connect].
  Stream<CompanionEvent> get events => _events.stream;

  bool get isConnected => _channel != null;

  /// The generation this connection runs at.
  int get generation => _generation;

  /// Connects and waits for the host's `host.status`.
  ///
  /// With [transport] (the LAN path after discovery, or a test loopback) the
  /// link is used as-is at [generation] (default: the stored counter).
  /// Without it, the relay is dialled at the stored counter, probing forward
  /// through [kCompanionProbeWindow] generations for a host whose counter
  /// fell behind. On success the NEXT counter is persisted, so the following
  /// session lands on a fresh rendezvous.
  Future<RemoteHostStatus> connect({
    RemoteTransport? transport,
    int? generation,
    Duration helloTimeout = const Duration(seconds: 8),
  }) async {
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
      final dialled = _relayFactory(_pairing.relay, rendezvous);
      try {
        final status = await _attach(dialled, g, true, helloTimeout);
        await _persistNextCounter(g);
        return status;
      } on TimeoutException {
        onLog?.call('no host at generation $g; probing forward');
        await _detach();
        await dialled.close();
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
    final arrived = _statusArrived = Completer<RemoteHostStatus>();
    _subscription = transport.frames.listen(_onFrame);
    final rendezvous = await rendezvousFor(_key, generation);
    transport.send(LinkHello(rendezvous).encode());
    return arrived.future.timeout(helloTimeout);
  }

  /// Re-proves the host is still at the far end of a socket that came back.
  ///
  /// A relay accepts a socket at a rendezvous whether or not anybody else is
  /// there, so a reconnected transport says nothing about the host. This
  /// re-sends [LinkHello] on the SAME channel and waits for a fresh
  /// `host.status`: the host tolerates a repeat hello — it reattaches the
  /// transport, keeps the channel and its sequences, and re-announces — so
  /// nothing about the key schedule or the replay window moves.
  ///
  /// Throws [TimeoutException] when nobody answers, which is the caller's cue
  /// that the link is dead however healthy the socket looks.
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
    await _subscription?.cancel();
    _subscription = null;
    _transport = null;
    _channel = null;
    _statusArrived = null;
  }

  Future<void> _persistNextCounter(int usedGeneration) async {
    // Bump after a connection pairs (loop 64): the next session dials fresh.
    _pairing = _pairing.withGeneration(usedGeneration + 1);
    await _pairing.save(store);
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
    final Envelope envelope;
    try {
      envelope = Envelope.fromBytes(opened.plaintext, accept: VersionRange.any);
    } on ProtocolException {
      return;
    }
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
        final pending = _pending.remove(envelope.id);
        if (pending != null) {
          pending.completeError(error);
        } else {
          onLog?.call('host error: ${error.code?.wire}');
        }
      case FrameType.hostStatus:
        try {
          final status = RemoteHostStatus.fromJson(envelope.payload);
          if (_statusArrived?.isCompleted == false) {
            _statusArrived!.complete(status);
          }
          _emit(HostStatusEvent(status));
        } on ProtocolException {
          return;
        }
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
      case FrameType.approvalRequested:
        _tolerant(
          () => _emit(
            ApprovalRequestedEvent(
              RemoteApprovalRequest.fromJson(envelope.payload),
            ),
          ),
        );
      default:
        // A frame from a newer host; nothing to do with it here.
        onLog?.call('ignored a frame of type ${envelope.type}');
    }
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

  Future<List<RemoteSessionSnapshot>> listSessions() async =>
      [for (final row in await listSessionRows()) row.snapshot];

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

  Future<void> sendPrompt(String sessionId, String text) async {
    await _request(FrameType.promptSend, {
      'sessionId': sessionId,
      'text': text,
    });
  }

  /// Answers a pending approval; returns the label of the key the host
  /// pressed, in the agent's own words.
  Future<String> answerApproval(
    String sessionId, {
    required bool approve,
    String? approvalId,
  }) async {
    final payload = await _request(FrameType.approvalAnswer, {
      'sessionId': sessionId,
      'decision': approve ? 'approve' : 'deny',
      'approvalId': ?approvalId,
    });
    final pressed = payload['pressed'];
    return pressed is String ? pressed : '';
  }

  Future<void> registerNotifications({
    required String token,
    required String platform,
  }) async {
    await _request(FrameType.notificationsRegister, {
      'token': token,
      'platform': platform,
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
    _sendChain = _sendChain.then((_) async {
      final envelope = Envelope.of(
        type,
        seq: channel.nextSendSequence,
        id: id,
        payload: payload,
      );
      transport.send(await channel.seal(envelope.toBytes()));
    });
    await _sendChain;
    try {
      return await completer.future.timeout(requestTimeout);
    } on TimeoutException {
      _pending.remove(id);
      throw const RemoteApiException('the host did not answer');
    }
  }

  Future<void> close() async {
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

/// Builds the relay transport for one rendezvous — a seam for tests.
typedef RelayTransportFactoryFn =
    RemoteTransport Function(Uri relay, RendezvousId rendezvous);
