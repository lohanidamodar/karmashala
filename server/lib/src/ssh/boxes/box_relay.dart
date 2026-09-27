import 'dart:async';

import 'package:karmashala_host_protocol/protocol.dart';
import 'package:karmashala_ssh_host/host.dart';

import '../../domain/write_token.dart';
import 'remote_sessions.dart';
import 'server_remote_hosts.dart';

/// **The frame relay** (slice 5d): a client attached to a box session at its
/// own server is relayed the box host's frames under its own ref — output,
/// the screen, the exit, exactly as the box sent them. The box sees only the
/// server, so the one-writer rule is kept here, per box session, over the
/// server's clients. A link to the box that drops hangs the client up, so its
/// pane dials again and is relayed on a fresh link; the session goes on at
/// the box.
class ServerBoxRelay implements BoxRelay {
  ServerBoxRelay(this._boxes);

  final ServerRemoteHosts _boxes;

  @override
  bool relays(String sessionId) => _boxes.resolve(sessionId) != null;

  @override
  BoxRelayClient clientFor(BoxRelayPeer peer) => _RelayClient(_boxes, peer);
}

class _RelayClient implements BoxRelayClient {
  _RelayClient(this._boxes, this._peer);

  final ServerRemoteHosts _boxes;
  final BoxRelayPeer _peer;
  final _relayed = <int, _Relayed>{};

  @override
  bool holds(int ref) => _relayed.containsKey(ref);

  @override
  void attach(AttachMessage message) => unawaited(_attach(message));

  Future<void> _attach(AttachMessage message) async {
    final box = _boxes.resolve(message.sessionId);
    if (box == null) {
      _peer.send(
        ErrorMessage(
          message.requestId,
          ProtocolErrorCode.unknownSession,
          'no session "${message.sessionId}" on this server',
        ),
      );
      return;
    }
    final BoxRoute route;
    try {
      route = await _boxes.attach(
        hostId: box.hostId,
        sessionId: box.sessionId,
        sinceOffset: message.sinceOffset,
        screenGrid: message.screenGrid,
      );
    } on BoxUnavailable catch (e) {
      _peer.send(
        ErrorMessage(message.requestId, ProtocolErrorCode.unknownSession, '$e'),
      );
      return;
    } on BoxLinkException catch (e) {
      _peer.send(
        ErrorMessage(
          message.requestId,
          e.code ?? ProtocolErrorCode.internal,
          e.message,
        ),
      );
      return;
    }
    if (_peer.hungUp) {
      route.detach();
      return;
    }
    final now = _peer.now();
    final clientId = _peer.clientId;
    final token = _boxes.tokenOf(box.hostId, box.sessionId);
    String? holder = token.holder?.clientId;
    if (message.claimWrite) {
      final refusal = token.claim(clientId, now);
      holder = refusal?.holder?.clientId ?? clientId;
    }
    final ref = _peer.nextRef();
    final relayed = _Relayed(box.hostId, box.sessionId, route, token);
    _relayed[ref] = relayed;
    final answered = route.attached;
    _peer.send(
      AttachedMessage(
        requestId: message.requestId,
        sessionRef: ref,
        sessionId: message.sessionId,
        columns: answered.columns,
        rows: answered.rows,
        replayFromOffset: answered.replayFromOffset,
        droppedBytes: answered.droppedBytes,
        totalBytes: answered.totalBytes,
        holdsWriteToken: token.isHeldBy(clientId),
        writeHolder: holder,
        observedAt: now,
        screenFollows: answered.screenFollows,
      ),
    );
    final grid = message.screenGrid;
    if (grid != null) _boxes.resized(box.hostId, box.sessionId, grid.$1, grid.$2);
    late final StreamSubscription<HostMessage> subscription;
    subscription = route.frames.listen(
      (frame) {
        switch (frame) {
          case OutputMessage(:final offset, :final bytes):
            _peer.send(OutputMessage(ref, offset, bytes));
            _peer.pace(subscription);
          case ScreenMessage(:final offset, :final bytes):
            _peer.send(ScreenMessage(ref, offset, bytes));
          case ExitedMessage():
            _peer.send(
              ExitedMessage(
                sessionRef: ref,
                sessionId: message.sessionId,
                exitCode: frame.exitCode,
                reason: frame.reason,
                observedAt: frame.observedAt,
              ),
            );
          default:
            break;
        }
      },
      onDone: () {
        if (_relayed.remove(ref) == null || route.exited || _peer.hungUp) {
          return;
        }
        // The link to the box went, not the session: the client dials again.
        _peer.hangUp();
      },
    );
    relayed.subscription = subscription;
  }

  @override
  Future<void> close(CloseMessage message) async {
    final box = _boxes.resolve(message.sessionId);
    if (box == null) {
      _peer.send(
        ErrorMessage(
          message.requestId,
          ProtocolErrorCode.unknownSession,
          'no session "${message.sessionId}" on this server',
        ),
      );
      return;
    }
    try {
      final code = await _boxes.closeOn(
        box.hostId,
        box.sessionId,
        signal: message.signal,
      );
      _peer.send(ClosedMessage(message.requestId, message.sessionId, code));
    } on Object catch (e) {
      _peer.send(
        ErrorMessage(
          message.requestId,
          e is BoxLinkException && e.code != null
              ? e.code!
              : ProtocolErrorCode.unknownSession,
          '$e',
        ),
      );
    }
  }

  @override
  void input(InputMessage message) {
    final relayed = _relayed[message.sessionRef];
    if (relayed == null) return;
    if (_refused(relayed)) return;
    relayed.route.input(message.bytes);
  }

  @override
  void resize(ResizeMessage message) {
    final relayed = _relayed[message.sessionRef];
    if (relayed == null) return;
    if (_refused(relayed)) return;
    relayed.route.resize(message.columns, message.rows);
    _boxes.resized(
      relayed.hostId,
      relayed.sessionId,
      message.columns,
      message.rows,
    );
  }

  /// Whether this client may not type or resize; said to it when so.
  bool _refused(_Relayed relayed) {
    final clientId = _peer.clientId;
    if (relayed.token.isHeldBy(clientId)) return false;
    final now = _peer.now();
    final holder = relayed.token.holder;
    _peer.send(
      ErrorMessage(
        0,
        ProtocolErrorCode.writeRefused,
        holder == null
            ? ClaimRefusal.unclaimed(now).message
            : ClaimRefusal.heldBy(holder, now).message,
      ),
    );
    return true;
  }

  @override
  void claim(ClaimMessage message) {
    final relayed = _relayed[message.sessionRef];
    if (relayed == null) return;
    final refusal = relayed.token.claim(_peer.clientId, _peer.now());
    if (refusal != null) {
      _peer.send(
        ErrorMessage(
          message.requestId,
          ProtocolErrorCode.writeRefused,
          refusal.message,
        ),
      );
      return;
    }
    _peer.send(
      ClaimedMessage(
        requestId: message.requestId,
        sessionRef: message.sessionRef,
        holdsWriteToken: true,
        writeHolder: _peer.clientId,
      ),
    );
  }

  @override
  void release(ReleaseMessage message) {
    final relayed = _relayed[message.sessionRef];
    if (relayed == null) return;
    relayed.token.release(_peer.clientId);
    _peer.send(
      ClaimedMessage(
        requestId: message.requestId,
        sessionRef: message.sessionRef,
        holdsWriteToken: false,
        writeHolder: relayed.token.holder?.clientId,
      ),
    );
  }

  @override
  Future<void> detach(int ref) async => _relayed.remove(ref)?.stop();

  @override
  Future<void> dispose() async {
    for (final relayed in _relayed.values.toList()) {
      await relayed.stop();
    }
    _relayed.clear();
    final clientId = _peer.clientId;
    if (clientId.isNotEmpty) _boxes.forgetClient(clientId);
  }
}

/// One attachment relayed from a box to one client.
class _Relayed {
  _Relayed(this.hostId, this.sessionId, this.route, this.token);

  final String hostId;
  final String sessionId;
  final BoxRoute route;
  final WriteToken token;
  StreamSubscription<HostMessage>? subscription;

  Future<void> stop() async {
    await subscription?.cancel();
    route.detach();
  }
}
