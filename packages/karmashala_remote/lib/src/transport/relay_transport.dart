/// The relay client, used unchanged by both ends: each opens an outbound
/// WebSocket to `wss://<relay>/v1/<rendezvous>` and the relay pairs them.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../protocol.dart';
import 'remote_transport.dart';

/// How often the client pings the relay, so a dead link is noticed rather than
/// waiting on a TCP timeout. Also what keeps a mobile NAT binding alive.
const Duration kDefaultHeartbeat = Duration(seconds: 25);

/// How long one connection attempt may take before it counts as failed.
const Duration kDefaultConnectTimeout = Duration(seconds: 15);

/// The relay's "nobody was at the other end" close code — `kCloseNoPeer` in
/// `packages/relay`, repeated here rather than imported so the phone's
/// transport does not depend on the relay server.
const int kRelayCloseNoPeer = 4408;

/// An outbound WebSocket to a relay rendezvous, with reconnect and heartbeat.
class RelayTransport extends ReconnectingTransport {
  RelayTransport({
    required this.endpoint,
    this.heartbeat = kDefaultHeartbeat,
    this.connectTimeout = kDefaultConnectTimeout,
    super.backoff,
    super.maxQueuedFrames,
    super.maxQueuedBytes,
    super.onLog,
  });

  /// Builds the transport for [rendezvous] on [relay] and starts connecting.
  factory RelayTransport.connect({
    required Uri relay,
    required RendezvousId rendezvous,
    Duration heartbeat = kDefaultHeartbeat,
    Duration connectTimeout = kDefaultConnectTimeout,
    Backoff? backoff,
    int maxQueuedFrames = 256,
    void Function(String message)? onLog,
  }) => RelayTransport(
    endpoint: endpointFor(relay, rendezvous),
    heartbeat: heartbeat,
    connectTimeout: connectTimeout,
    backoff: backoff,
    maxQueuedFrames: maxQueuedFrames,
    onLog: onLog,
  )..start();

  /// The full `ws(s)://…/v1/<rendezvous>` URL both ends meet on.
  final Uri endpoint;
  final Duration heartbeat;
  final Duration connectTimeout;

  /// The live socket. `dart:io`'s [WebSocket] rather than a `WebSocketChannel`
  /// wrapper: closing the wrapper's sink does **not** close the socket, and a
  /// listener the relay still counts is what wedges a re-registration.
  WebSocket? _socket;

  /// Maps a relay base URL onto the rendezvous path, upgrading http(s) to ws(s).
  static Uri endpointFor(Uri relay, RendezvousId rendezvous) {
    final scheme = switch (relay.scheme) {
      'https' || 'wss' => 'wss',
      'http' || 'ws' => 'ws',
      final other => throw TransportException('unusable relay scheme: $other'),
    };
    final base = relay.path.endsWith('/')
        ? relay.path.substring(0, relay.path.length - 1)
        : relay.path;
    return relay.replace(scheme: scheme, path: '$base/v1/${rendezvous.value}');
  }

  /// The code the relay last hung up with, or null while none has been seen.
  /// [kRelayCloseNoPeer] means "nobody else was ever there" — a different thing
  /// to tell a user than "the network failed".
  int? get lastCloseCode => _lastCloseCode;
  int? _lastCloseCode;

  @override
  Future<void> connectOnce() async {
    // `.timeout()` cancels nothing: a socket that opens after it fired would
    // hold the rendezvous generation for a transport that has moved on.
    final pending = WebSocket.connect(endpoint.toString());
    final WebSocket socket;
    try {
      socket = await pending.timeout(connectTimeout);
    } on TimeoutException {
      unawaited(
        pending.then<void>(
          (late) => late.close(WebSocketStatus.goingAway, 'timed out'),
          onError: (Object _) {},
        ),
      );
      rethrow;
    }
    socket.pingInterval = heartbeat;
    // Closed while this dial was in flight: `abort()` had no socket to close,
    // so the connection would come up after the transport was gone and hold the
    // rendezvous, and the relay would pair the next listener with that orphan.
    if (state == TransportState.closed) {
      await socket.close(WebSocketStatus.goingAway, 'closing');
      return;
    }
    _socket = socket;
    onConnected();

    final ended = Completer<void>();
    final subscription = socket.listen(
      (Object? message) {
        if (message is List<int>) {
          onFrame(Uint8List.fromList(message));
        } else {
          // Sealed frames are always binary; anything else is not our peer.
          onLog?.call('ignored a non-binary relay message');
        }
      },
      onError: (Object error) {
        onLog?.call('relay stream failed: $error');
        if (!ended.isCompleted) ended.complete();
      },
      onDone: () {
        if (!ended.isCompleted) ended.complete();
      },
      cancelOnError: true,
    );

    await ended.future;
    await subscription.cancel();
    _socket = null;
    _lastCloseCode = socket.closeCode;
    onLog?.call('relay closed the connection (${socket.closeCode})');
  }

  @override
  bool writeFrame(Uint8List frame) {
    final socket = _socket;
    if (socket == null) return false;
    socket.add(frame);
    return true;
  }

  /// Closes the socket itself with an explicit code, so the relay frees the
  /// rendezvous immediately and the next listener can take it.
  @override
  Future<void> abort() async {
    final socket = _socket;
    _socket = null;
    await socket?.close(WebSocketStatus.goingAway, 'closing');
  }
}
