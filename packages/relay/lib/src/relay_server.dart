import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Port the relay listens on when nothing says otherwise.
const int kDefaultRelayPort = 8787;

/// How long a socket waits alone at a rendezvous before it is dropped.
const Duration kDefaultLoneTimeout = Duration(minutes: 2);

/// Largest frame the relay will forward. The app's own envelope cap is 1 MiB;
/// the slack covers the sealing overhead.
const int kDefaultMaxFrameBytes = 1024 * 1024 + 4096;

/// New connections one IP may make per minute, and the burst it may spend.
const int kDefaultConnectionsPerMinute = 60;

/// Rendezvous the relay will hold at once before it starts refusing.
const int kDefaultMaxRendezvous = 10000;

/// How often the relay pings a quiet socket to notice a dead peer.
const Duration kDefaultPingInterval = Duration(seconds: 30);

/// Frames the first socket may send before its peer arrives.
const int kMaxPendingFrames = 8;

/// Close codes the relay uses. WebSocket only lets an application send 1000 or
/// 3000-4999, so every refusal is in the 4000s and mirrors its HTTP cousin.
const int kClosePeerLeft = 1000;
const int kClosePeerFailed = 4001;
const int kCloseNoPeer = 4408;
const int kCloseBusy = 4409;
const int kCloseFrameTooLarge = 4413;
const int kCloseImpatient = 4429;

/// A rendezvous path: `v1/` and 32 lowercase hex characters.
final RegExp _rendezvousPattern = RegExp(r'^v1/([0-9a-f]{32})$');

/// Knobs an operator can turn. None of them change what the relay can see.
class RelayOptions {
  const RelayOptions({
    this.loneTimeout = kDefaultLoneTimeout,
    this.maxFrameBytes = kDefaultMaxFrameBytes,
    this.connectionsPerMinute = kDefaultConnectionsPerMinute,
    this.maxRendezvous = kDefaultMaxRendezvous,
    this.pingInterval = kDefaultPingInterval,
    this.onLog,
  });

  final Duration loneTimeout;
  final int maxFrameBytes;

  /// Zero or less turns the per-IP limit off.
  final int connectionsPerMinute;
  final int maxRendezvous;
  final Duration pingInterval;

  /// Lifecycle only — the relay never logs a rendezvous id or a frame.
  final void Function(String message)? onLog;
}

/// A dumb pipe: it pairs two outbound WebSockets by rendezvous id and forwards
/// whatever they send, never looking inside and never logging an id.
class RelayServer {
  RelayServer._(this.options);

  /// Binds and starts serving. Pass port 0 for an ephemeral port.
  static Future<RelayServer> bind({
    Object address = '0.0.0.0',
    int port = kDefaultRelayPort,
    RelayOptions options = const RelayOptions(),
  }) async {
    final relay = RelayServer._(options);
    relay._server = await shelf_io.serve(
      relay._handle,
      address,
      port,
      poweredByHeader: null,
    );
    return relay;
  }

  final RelayOptions options;
  late final HttpServer _server;

  final Map<String, _Rendezvous> _rendezvous = <String, _Rendezvous>{};
  final _RateLimiter _limiter = _RateLimiter();
  final DateTime _startedAt = DateTime.now();

  int get port => _server.port;
  InternetAddress get address => _server.address;

  /// Rendezvous currently held, paired or waiting.
  int get rendezvousCount => _rendezvous.length;

  Future<void> close() async {
    for (final rendezvous in _rendezvous.values.toList()) {
      rendezvous.dispose(kCloseNoPeer, 'relay closing');
    }
    _rendezvous.clear();
    await _server.close(force: true);
  }

  FutureOr<Response> _handle(Request request) {
    if (request.url.path == 'healthz') return _health();

    final match = _rendezvousPattern.firstMatch(request.url.path);
    if (match == null) return Response.notFound('not found\n');
    final id = match.group(1)!;

    if (!_limiter.allow(_clientIp(request), options.connectionsPerMinute)) {
      _log('rate limited a client');
      return Response(429, body: 'slow down\n');
    }

    final existing = _rendezvous[id];
    if (existing != null && existing.isFull) {
      _log('refused a third socket');
      return Response(409, body: 'rendezvous busy\n');
    }
    if (existing == null && _rendezvous.length >= options.maxRendezvous) {
      return Response(503, body: 'relay full\n');
    }

    return webSocketHandler(
      (WebSocketChannel socket, _) => _join(id, socket),
      pingInterval: options.pingInterval,
    )(request);
  }

  Response _health() => Response.ok(
    jsonEncode({
      'status': 'ok',
      'rendezvous': _rendezvous.length,
      'sockets': _rendezvous.values.fold<int>(0, (n, r) => n + r.socketCount),
      'uptime_s': DateTime.now().difference(_startedAt).inSeconds,
    }),
    headers: const {'content-type': 'application/json'},
  );

  void _join(String id, WebSocketChannel socket) {
    final existing = _rendezvous[id];
    if (existing == null) {
      _rendezvous[id] = _Rendezvous(
        socket,
        options: options,
        onEmpty: () => _rendezvous.remove(id),
      );
      _log('a socket is waiting ($rendezvousCount held)');
      return;
    }
    if (existing.isFull) {
      // Lost the race with the pre-upgrade check; refuse now instead.
      socket.sink.close(kCloseBusy, 'rendezvous busy');
      return;
    }
    existing.pair(socket);
    _log('paired ($rendezvousCount held)');
  }

  void _log(String message) => options.onLog?.call(message);
}

/// One rendezvous: a waiting socket, then a pair forwarding to each other.
class _Rendezvous {
  _Rendezvous(this._first, {required this.options, required this.onEmpty}) {
    _subscriptions.add(_attach(_first));
    _loneTimer = Timer(
      options.loneTimeout,
      () => dispose(kCloseNoPeer, 'no peer'),
    );
  }

  final WebSocketChannel _first;
  final RelayOptions options;
  final void Function() onEmpty;

  WebSocketChannel? _second;
  Timer? _loneTimer;
  final List<StreamSubscription<Object?>> _subscriptions = [];

  /// What the first socket sent before its peer arrived. Bounded, because a
  /// relay that buffers is no longer a pipe.
  final List<Object?> _pending = [];
  bool _disposed = false;

  bool get isFull => _second != null;
  int get socketCount => isFull ? 2 : 1;

  void pair(WebSocketChannel second) {
    _loneTimer?.cancel();
    _loneTimer = null;
    _second = second;
    _subscriptions.add(_attach(second));
    for (final frame in _pending) {
      second.sink.add(frame);
    }
    _pending.clear();
  }

  StreamSubscription<Object?> _attach(WebSocketChannel from) =>
      from.stream.listen(
        (Object? frame) => _forward(from, frame),
        onDone: () => dispose(kClosePeerLeft, 'peer left'),
        onError: (Object _) => dispose(kClosePeerFailed, 'peer failed'),
        cancelOnError: true,
      );

  void _forward(WebSocketChannel from, Object? frame) {
    final size = frame is String
        ? frame.length
        : (frame is List<int> ? frame.length : 0);
    if (size > options.maxFrameBytes) {
      dispose(kCloseFrameTooLarge, 'frame too large');
      return;
    }
    final to = identical(from, _first) ? _second : _first;
    if (to == null) {
      if (_pending.length >= kMaxPendingFrames) {
        dispose(kCloseImpatient, 'sent too much before pairing');
        return;
      }
      _pending.add(frame);
      return;
    }
    to.sink.add(frame);
  }

  void dispose(int code, String reason) {
    if (_disposed) return;
    _disposed = true;
    _loneTimer?.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
    _pending.clear();
    _first.sink.close(code, reason);
    _second?.sink.close(code, reason);
    onEmpty();
  }
}

/// A token bucket per client IP, refilled continuously.
class _RateLimiter {
  final Map<String, _Bucket> _buckets = <String, _Bucket>{};

  bool allow(String key, int perMinute) {
    if (perMinute <= 0) return true;
    final now = DateTime.now();
    if (_buckets.length > 4096) {
      _buckets.removeWhere(
        (_, bucket) =>
            now.difference(bucket.updatedAt) > const Duration(minutes: 5),
      );
    }
    final bucket = _buckets.putIfAbsent(
      key,
      () => _Bucket(perMinute.toDouble(), now),
    );
    final elapsed = now.difference(bucket.updatedAt).inMicroseconds / 1e6;
    bucket
      ..tokens = (bucket.tokens + elapsed * perMinute / 60).clamp(
        0,
        perMinute.toDouble(),
      )
      ..updatedAt = now;
    if (bucket.tokens < 1) return false;
    bucket.tokens -= 1;
    return true;
  }
}

class _Bucket {
  _Bucket(this.tokens, this.updatedAt);

  double tokens;
  DateTime updatedAt;
}

String _clientIp(Request request) {
  final forwarded =
      request.headers['fly-client-ip'] ?? request.headers['x-forwarded-for'];
  if (forwarded != null && forwarded.isNotEmpty) {
    return forwarded.split(',').first.trim();
  }
  final info = request.context['shelf.io.connection_info'];
  if (info is HttpConnectionInfo) return info.remoteAddress.address;
  return 'unknown';
}
