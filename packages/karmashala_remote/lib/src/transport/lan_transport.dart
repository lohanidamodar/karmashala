/// The direct path: a plain TCP socket on the same network, skipping the relay.
/// No TLS — the frames are already sealed end to end.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'remote_transport.dart';

/// The port the host listens on when nothing says otherwise. Advertised in the
/// beacon, so a host that cannot get this one still gets found.
const int kDefaultLanPort = 47653;

/// How long a dial may take before it counts as a failed attempt.
const Duration kLanConnectTimeout = Duration(seconds: 5);

/// The companion's end of the direct path: dials the host and keeps redialling.
class LanTransport extends ReconnectingTransport {
  LanTransport({
    required this.host,
    required this.port,
    this.connectTimeout = kLanConnectTimeout,
    super.backoff,
    super.maxQueuedFrames,
    super.maxQueuedBytes,
    super.onLog,
  });

  /// Builds the transport and starts dialling.
  factory LanTransport.dial({
    required String host,
    required int port,
    Duration connectTimeout = kLanConnectTimeout,
    Backoff? backoff,
    int maxQueuedFrames = 256,
    void Function(String message)? onLog,
  }) => LanTransport(
    host: host,
    port: port,
    connectTimeout: connectTimeout,
    backoff: backoff,
    maxQueuedFrames: maxQueuedFrames,
    onLog: onLog,
  )..start();

  final String host;
  final int port;
  final Duration connectTimeout;

  Socket? _socket;

  @override
  Future<void> connectOnce() async {
    final socket = await Socket.connect(host, port, timeout: connectTimeout);
    _socket = socket;
    await _pump(socket, this);
    _socket = null;
  }

  @override
  bool writeFrame(Uint8List frame) => _write(_socket, frame);

  @override
  Future<void> abort() async {
    final socket = _socket;
    _socket = null;
    socket?.destroy();
  }
}

/// One connection the host accepted. It never redials: the phone does that, and
/// the listener hands out a fresh link when it does.
class LanLink extends ReconnectingTransport {
  LanLink(this._socket, {super.onLog});

  Socket? _socket;

  /// Where the phone dialled from.
  InternetAddress? get remoteAddress => _socket?.remoteAddress;

  @override
  bool get reconnects => false;

  @override
  Future<void> connectOnce() async {
    final socket = _socket;
    if (socket == null) return;
    await _pump(socket, this);
    _socket = null;
  }

  @override
  bool writeFrame(Uint8List frame) => _write(_socket, frame);

  @override
  Future<void> abort() async {
    final socket = _socket;
    _socket = null;
    socket?.destroy();
  }
}

/// The host's end of the direct path: a TCP listener handing out one [LanLink]
/// per phone that dials in.
class LanTransportServer {
  LanTransportServer._(this._server, this._onLog) {
    _subscription = _server.listen(
      _accept,
      onError: (Object error) => _onLog?.call('listener failed: $error'),
    );
  }

  /// Binds a listener. Port 0 asks the OS for a free one.
  static Future<LanTransportServer> bind({
    Object address = '0.0.0.0',
    int port = kDefaultLanPort,
    void Function(String message)? onLog,
  }) async => LanTransportServer._(
    await ServerSocket.bind(address, port, shared: false),
    onLog,
  );

  final ServerSocket _server;
  final void Function(String message)? _onLog;

  /// Single-subscription for the same reason [RemoteTransport.frames] is: a
  /// phone that dials in before the host listens must not be dropped.
  final StreamController<LanLink> _connections = StreamController<LanLink>();
  final List<LanLink> _links = <LanLink>[];

  late final StreamSubscription<Socket> _subscription;

  int get port => _server.port;
  InternetAddress get address => _server.address;

  /// A link per phone that dials in, already started. Listen once.
  Stream<LanLink> get connections => _connections.stream;

  void _accept(Socket socket) {
    final link = LanLink(socket, onLog: _onLog)..start();
    _links.add(link);
    _onLog?.call('accepted a link');
    if (!_connections.isClosed) _connections.add(link);
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _server.close();
    for (final link in List<LanLink>.of(_links)) {
      await link.close();
    }
    _links.clear();
    // Not awaited, for the same reason the frame stream is not: a host that
    // never listened for connections would otherwise never finish closing.
    unawaited(_connections.close());
  }
}

/// Reads length-prefixed frames off [socket] until it ends.
Future<void> _pump(Socket socket, ReconnectingTransport transport) async {
  socket.setOption(SocketOption.tcpNoDelay, true);
  final framer = LengthPrefixedFramer();
  transport.onConnected();

  final ended = Completer<void>();
  final subscription = socket.listen(
    (Uint8List chunk) {
      try {
        for (final frame in framer.add(chunk)) {
          transport.onFrame(frame);
        }
      } on TransportFramingException catch (error) {
        transport.onLog?.call('dropping the link: ${error.message}');
        socket.destroy();
        if (!ended.isCompleted) ended.complete();
      }
    },
    onError: (Object error) {
      transport.onLog?.call('link failed: $error');
      if (!ended.isCompleted) ended.complete();
    },
    onDone: () {
      if (!ended.isCompleted) ended.complete();
    },
    cancelOnError: true,
  );

  // `_write` is `socket.add(...)`: a failed write does not throw at the call
  // site, it arrives later on `socket.done`, and with nobody listening it
  // escaped as an unhandled async error. A link that dies has to end the same
  // way whichever half noticed it.
  unawaited(
    socket.done.then<void>(
      (_) {},
      onError: (Object error) {
        transport.onLog?.call('link failed while writing: $error');
        if (!ended.isCompleted) ended.complete();
      },
    ),
  );

  await ended.future;
  await subscription.cancel();
  socket.destroy();
}

bool _write(Socket? socket, Uint8List frame) {
  if (socket == null) return false;
  socket.add(LengthPrefixedFramer.encode(frame));
  return true;
}
