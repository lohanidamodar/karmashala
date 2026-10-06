import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:karmashala_relay_protocol/karmashala_relay_protocol.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'push_delivery.dart';

/// How long a socket waits alone at a rendezvous before it is dropped. Zero or
/// less means never, which is right for the relay embedded in the desktop: a
/// lone socket there is the desktop's own listener waiting for an absent phone,
/// and evicting it evicts the operator. A shared relay keeps a real timeout.
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

/// Push registrations held at once before `/v1/push/register` starts refusing.
const int kDefaultMaxPushTokens = 10000;

/// Longest base64url push payload accepted — FCM caps a data message at 4 KiB.
const int kDefaultMaxPushPayloadBytes = 4096;

/// Hooks listeners the relay will hold at once before it starts refusing.
const int kDefaultMaxHookListeners = 10000;

/// Knobs an operator can turn. None of them change what the relay can see.
class RelayOptions {
  const RelayOptions({
    this.loneTimeout = kDefaultLoneTimeout,
    this.maxFrameBytes = kDefaultMaxFrameBytes,
    this.connectionsPerMinute = kDefaultConnectionsPerMinute,
    this.maxRendezvous = kDefaultMaxRendezvous,
    this.pingInterval = kDefaultPingInterval,
    this.delivery,
    this.maxPushTokens = kDefaultMaxPushTokens,
    this.maxPushPayloadBytes = kDefaultMaxPushPayloadBytes,
    this.trustedProxy = false,
    this.accessToken,
    this.hookCallsPerMinute = kDefaultHookCallsPerMinute,
    this.hookAnswerTimeout = kHookAnswerTimeout,
    this.maxHookListeners = kDefaultMaxHookListeners,
    this.onLog,
  });

  /// Calls one hooks listen id may receive a minute. Zero or less is no limit.
  final int hookCallsPerMinute;

  /// How long a call waits for its server's answer before a 504.
  final Duration hookAnswerTimeout;
  final int maxHookListeners;

  /// When set, every route is served only under `/k/<token>/` and anything
  /// else is an unknown path. Null — the default — leaves the relay open. An
  /// open relay on a public address forwards for whoever finds it; this stops
  /// that. Over plain `ws://` it is visible on the wire, so it is not secrecy.
  final String? accessToken;

  /// Whether a reverse proxy in front of the relay is trusted to say who the
  /// client is (`fly-client-ip`, or the last `x-forwarded-for` hop it added).
  /// Off, a client that writes the header itself would pick its own bucket.
  final bool trustedProxy;

  /// Zero or less turns the lone-socket eviction off — see
  /// [kDefaultLoneTimeout] for when that is the right answer.
  final Duration loneTimeout;
  final int maxFrameBytes;

  /// Zero or less turns the per-IP limit off.
  final int connectionsPerMinute;
  final int maxRendezvous;
  final Duration pingInterval;

  /// Where `/v1/push` hands an accepted request. Null — the default, and
  /// every test — leaves push delivery unconfigured: registration still
  /// works, push requests answer 503.
  final PushDelivery? delivery;

  final int maxPushTokens;
  final int maxPushPayloadBytes;

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
    final token = options.accessToken;
    if (token != null && !isUsableRelayToken(token)) {
      // Refused rather than served: a short or empty token is an open relay
      // that believes it is a closed one.
      throw ArgumentError('the access token must be 32+ url-safe characters');
    }
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

  /// tag → what to deliver with. In memory only: a restart forgets them, and
  /// the host re-registers when its next push answers `unknown tag`.
  final Map<String, ({String token, String platform})> _pushTokens = {};

  final _RateLimiter _limiter = _RateLimiter();

  /// listen id → the one server socket listening for its hooks.
  final Map<String, _HookListener> _hookListeners = {};
  final _RateLimiter _hookLimiter = _RateLimiter();
  final Random _random = Random.secure();
  final DateTime _startedAt = DateTime.now();

  int get port => _server.port;
  InternetAddress get address => _server.address;

  /// Rendezvous currently held, paired or waiting.
  int get rendezvousCount => _rendezvous.length;

  /// Push registrations currently held.
  int get pushTokenCount => _pushTokens.length;

  /// Hooks listeners currently held.
  int get hookListenerCount => _hookListeners.length;

  Future<void> close() async {
    for (final rendezvous in _rendezvous.values.toList()) {
      rendezvous.dispose(kCloseNoPeer, 'relay closing');
    }
    _rendezvous.clear();
    for (final listener in _hookListeners.values.toList()) {
      listener.dispose(kCloseNoPeer, 'relay closing');
    }
    _hookListeners.clear();
    await _server.close(force: true);
  }

  FutureOr<Response> _handle(Request request) {
    final path = _gatedPath(request.url.path);
    if (path == null) return Response.notFound('not found\n');
    if (path == kRelayHealthPath) return _health();
    if (path == kRelayPushRegisterPath) return _pushRegister(request);
    if (path == kRelayPushPath) return _pushSend(request);
    if (hooksListenKeyOf(path) case final key?) {
      return _hooksListen(request, key);
    }
    if (isHookCallRoute(path)) return _hookCall(request, path);

    final id = rendezvousIdOf(path);
    if (id == null) return Response.notFound('not found\n');

    final client = _clientIp(request, trustedProxy: options.trustedProxy);
    if (!_limiter.allow(client, options.connectionsPerMinute)) {
      _log('rate limited a client');
      return Response(RelayStatus.slowDown, body: 'slow down\n');
    }

    final existing = _rendezvous[id];
    if (existing != null && existing.isFull) {
      _log('refused a third socket');
      return Response(RelayStatus.rendezvousBusy, body: 'rendezvous busy\n');
    }
    if (existing == null && _rendezvous.length >= options.maxRendezvous) {
      return Response(RelayStatus.unavailable, body: 'relay full\n');
    }

    return webSocketHandler(
      (WebSocketChannel socket, _) => _join(id, socket),
      pingInterval: options.pingInterval,
    )(request);
  }

  /// The route inside the token prefix, or null when the request is not under
  /// it. Every miss reads the same — a wrong token is an unknown path.
  String? _gatedPath(String path) {
    final token = options.accessToken;
    if (token == null) return path;
    final segments = path.split('/');
    if (segments.length < 3 || segments[0] != kRelayAccessTokenSegment) {
      return null;
    }
    if (!_constantTimeEquals(segments[1], token)) return null;
    return segments.skip(2).join('/');
  }

  Response _health() => Response.ok(
    jsonEncode({
      'status': 'ok',
      'rendezvous': _rendezvous.length,
      'sockets': _rendezvous.values.fold<int>(0, (n, r) => n + r.socketCount),
      'push_tokens': _pushTokens.length,
      'push_delivery': options.delivery == null ? 'not configured' : 'ok',
      'hook_listeners': _hookListeners.length,
      'uptime_s': DateTime.now().difference(_startedAt).inSeconds,
    }),
    headers: const {'content-type': 'application/json'},
  );

  /// `POST /v1/push/register` `{tag, token, platform}` → 204. The tag is an
  /// opaque client-derived label; the relay stores token-by-tag and nothing
  /// else, and works whether or not delivery is configured.
  Future<Response> _pushRegister(Request request) async {
    final refused = await _readPushBody(request, 16 * 1024);
    if (refused is Response) return refused;
    final registration = PushRegistration.tryParse(
      refused as Map<String, Object?>,
    );
    if (registration == null) {
      return Response(RelayStatus.badRequest, body: 'bad request\n');
    }
    final PushRegistration(:tag, :token, :platform) = registration;
    if (!_pushTokens.containsKey(tag) &&
        _pushTokens.length >= options.maxPushTokens) {
      return Response(RelayStatus.unavailable, body: 'relay full\n');
    }
    _pushTokens[tag] = (token: token, platform: platform);
    _log('a push token registered (${_pushTokens.length} held)');
    return Response(RelayStatus.pushRegistered);
  }

  /// `POST /v1/push` `{tag, payload}` — payload is opaque base64url
  /// ciphertext, forwarded to the delivery boundary and never inspected.
  Future<Response> _pushSend(Request request) async {
    final refused = await _readPushBody(
      request,
      options.maxPushPayloadBytes + 1024,
    );
    if (refused is Response) return refused;
    final push = PushRequest.tryParse(refused as Map<String, Object?>);
    if (push == null) {
      return Response(RelayStatus.badRequest, body: 'bad request\n');
    }
    final PushRequest(:tag, :payload) = push;
    if (payload.length > options.maxPushPayloadBytes) {
      return Response(RelayStatus.tooLarge, body: 'payload too large\n');
    }
    final delivery = options.delivery;
    if (delivery == null) {
      _log('push refused: not configured');
      return Response(
        RelayStatus.unavailable,
        body: 'push delivery not configured\n',
      );
    }
    final registration = _pushTokens[tag];
    if (registration == null) {
      return Response(RelayStatus.notFound, body: 'unknown tag\n');
    }
    try {
      await delivery.deliver(
        token: registration.token,
        platform: registration.platform,
        payload: payload,
      );
    } on PushTokenGoneException {
      _pushTokens.remove(tag);
      _log('a push token expired (${_pushTokens.length} held)');
      return Response(RelayStatus.tokenGone, body: 'token gone\n');
    } on Object {
      _log('a push failed');
      return Response(RelayStatus.deliveryFailed, body: 'delivery failed\n');
    }
    _log('a push forwarded');
    return Response(RelayStatus.pushAccepted, body: 'accepted\n');
  }

  /// Common gate for the two push posts: method, rate limit, body size, JSON.
  /// Returns the decoded map, or the refusal to send instead.
  Future<Object> _readPushBody(Request request, int maxBytes) async {
    if (request.method != 'POST') {
      return Response(
        RelayStatus.methodNotAllowed,
        body: 'method not allowed\n',
      );
    }
    final client = _clientIp(request, trustedProxy: options.trustedProxy);
    if (!_limiter.allow(client, options.connectionsPerMinute)) {
      _log('rate limited a client');
      return Response(RelayStatus.slowDown, body: 'slow down\n');
    }
    final bytes = <int>[];
    await for (final chunk in request.read()) {
      bytes.addAll(chunk);
      if (bytes.length > maxBytes) {
        return Response(RelayStatus.tooLarge, body: 'body too large\n');
      }
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      return Response(RelayStatus.badRequest, body: 'bad request\n');
    }
    if (decoded is! Map<String, Object?>) {
      return Response(RelayStatus.badRequest, body: 'bad request\n');
    }
    return decoded;
  }

  /// `GET v1/hooks/<listen key>`: a server's hooks listener. The listen id is
  /// derived here from the key, so knowing a hook URL is not enough to listen.
  FutureOr<Response> _hooksListen(Request request, String listenKey) {
    final client = _clientIp(request, trustedProxy: options.trustedProxy);
    if (!_limiter.allow(client, options.connectionsPerMinute)) {
      _log('rate limited a client');
      return Response(RelayStatus.slowDown, body: 'slow down\n');
    }
    final listenId = hooksListenIdOf(listenKey);
    if (!_hookListeners.containsKey(listenId) &&
        _hookListeners.length >= options.maxHookListeners) {
      return Response(RelayStatus.unavailable, body: 'relay full\n');
    }
    return webSocketHandler((WebSocketChannel socket, _) {
      // The key holder reconnecting after a half-open socket: newest wins.
      _hookListeners[listenId]?.dispose(kCloseReplaced, 'replaced');
      late final _HookListener listener;
      listener = _HookListener(
        socket,
        onGone: () {
          if (identical(_hookListeners[listenId], listener)) {
            _hookListeners.remove(listenId);
          }
        },
      );
      _hookListeners[listenId] = listener;
      socket.sink.add(
        HooksReady(
          listenId: listenId,
          timeoutMs: options.hookAnswerTimeout.inMilliseconds,
        ).encode(),
      );
      _log('a hooks listener connected (${_hookListeners.length} held)');
    }, pingInterval: options.pingInterval)(request);
  }

  /// `POST h/<listen id>/<hook id>`: forwarded to that listener as one frame,
  /// answered with what it answers. The body is held only while in flight.
  Future<Response> _hookCall(Request request, String path) async {
    if (request.method != 'POST') {
      return _hookError(
        HookStatus.methodNotAllowed,
        'method not allowed',
        headers: const {'allow': 'POST'},
      );
    }
    final route = hookCallOf(path);
    if (route == null) return _hookError(HookStatus.notFound, 'not found');
    final declared = request.contentLength;
    if (declared != null && declared > kHookMaxBodyBytes) {
      return _hookError(HookStatus.tooLarge, 'body too large');
    }
    if (!_hookLimiter.allow(route.listenId, options.hookCallsPerMinute)) {
      _log('rate limited a hook call');
      return _hookError(HookStatus.slowDown, 'slow down');
    }
    if (_hookListeners[route.listenId] == null) {
      return _hookError(HookStatus.serverOffline, 'server offline');
    }
    final body = BytesBuilder(copy: false);
    await for (final chunk in request.read()) {
      body.add(chunk);
      if (body.length > kHookMaxBodyBytes) {
        return _hookError(HookStatus.tooLarge, 'body too large');
      }
    }
    // Again: the listener may have gone while the body arrived.
    final listener = _hookListeners[route.listenId];
    if (listener == null) {
      return _hookError(HookStatus.serverOffline, 'server offline');
    }
    if (listener.inFlight >= kHookMaxInFlight) {
      return _hookError(HookStatus.slowDown, 'slow down');
    }
    final call = HookCall(
      id: _callId(),
      hookId: route.hookId,
      method: request.method,
      headers: {
        for (final name in kHookForwardedHeaders)
          if (request.headers[name] case final value?)
            name: value.length > kHookMaxHeaderValue
                ? value.substring(0, kHookMaxHeaderValue)
                : value,
      },
      body: body.takeBytes(),
      ip: _clientIp(request, trustedProxy: options.trustedProxy),
    );
    final outcome = await listener.forward(call, options.hookAnswerTimeout);
    return switch (outcome) {
      _Answered(:final answer) => Response(
        answer.status,
        body: jsonEncode(answer.body),
        headers: _hookHeaders,
      ),
      _Unanswered.badAnswer => _hookError(HookStatus.badAnswer, 'bad answer'),
      _Unanswered.gone => _hookError(
        HookStatus.serverOffline,
        'server offline',
      ),
      _Unanswered.timedOut => _hookError(
        HookStatus.timedOut,
        'server did not answer',
      ),
    };
  }

  static const Map<String, String> _hookHeaders = {
    'content-type': 'application/json',
    'cache-control': 'no-store',
  };

  static Response _hookError(
    int status,
    String words, {
    Map<String, String> headers = const {},
  }) => Response(
    status,
    body: hookErrorBody(words),
    headers: {..._hookHeaders, ...headers},
  );

  String _callId() => [
    for (var i = 0; i < 16; i++)
      _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();

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
    if (options.loneTimeout > Duration.zero) {
      _loneTimer = Timer(
        options.loneTimeout,
        () => dispose(kCloseNoPeer, 'no peer'),
      );
    }
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

/// Compares without stopping at the first difference, so how long a refusal
/// took says nothing about how much of the token was right.
bool _constantTimeEquals(String a, String b) {
  final left = utf8.encode(a);
  final right = utf8.encode(b);
  var diff = left.length ^ right.length;
  for (var i = 0; i < left.length; i++) {
    diff |= left[i] ^ right[i % right.length];
  }
  return diff == 0;
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

String _clientIp(Request request, {required bool trustedProxy}) {
  if (trustedProxy) {
    final direct = request.headers['fly-client-ip'];
    if (direct != null && direct.trim().isNotEmpty) return direct.trim();
    final forwarded = request.headers['x-forwarded-for'];
    if (forwarded != null && forwarded.trim().isNotEmpty) {
      // Right-most: the hop the proxy itself appended. Anything left of it
      // is whatever the client chose to send.
      return forwarded.split(',').last.trim();
    }
  }
  final info = request.context['shelf.io.connection_info'];
  if (info is HttpConnectionInfo) return info.remoteAddress.address;
  return 'unknown';
}

/// The listen id [listenKey] derives to — see [hooksListenIdInput].
String hooksListenIdOf(String listenKey) => sha256
    .convert(utf8.encode(hooksListenIdInput(listenKey)))
    .toString()
    .substring(0, 32);

sealed class _Outcome {}

final class _Answered implements _Outcome {
  _Answered(this.answer);
  final HookAnswer answer;
}

enum _Unanswered implements _Outcome { badAnswer, gone, timedOut }

/// One server's hooks socket, and the calls waiting on its answers.
class _HookListener {
  _HookListener(this._socket, {required this.onGone}) {
    _subscription = _socket.stream.listen(
      _onFrame,
      onDone: () => dispose(kClosePeerLeft, 'listener left'),
      onError: (Object _) => dispose(kClosePeerFailed, 'listener failed'),
      cancelOnError: true,
    );
  }

  final WebSocketChannel _socket;
  final void Function() onGone;
  late final StreamSubscription<Object?> _subscription;
  final Map<String, Completer<_Outcome>> _waiting = {};
  bool _disposed = false;

  int get inFlight => _waiting.length;

  Future<_Outcome> forward(HookCall call, Duration timeout) async {
    if (_disposed) return _Unanswered.gone;
    final answer = Completer<_Outcome>();
    _waiting[call.id] = answer;
    _socket.sink.add(call.encode());
    try {
      return await answer.future.timeout(
        timeout,
        onTimeout: () => _Unanswered.timedOut,
      );
    } finally {
      _waiting.remove(call.id);
    }
  }

  void _onFrame(Object? frame) {
    if (frame is! String || frame.length > kHookMaxAnswerBytes * 2) return;
    final Object? json;
    try {
      json = jsonDecode(frame);
    } on FormatException {
      return;
    }
    if (json is! Map<String, Object?> || json['type'] != HookAnswer.type) {
      return;
    }
    final waiting = _waiting.remove(json['id']);
    if (waiting == null || waiting.isCompleted) return;
    final answer = HookAnswer.tryParse(json);
    waiting.complete(
      answer == null ? _Unanswered.badAnswer : _Answered(answer),
    );
  }

  void dispose(int code, String reason) {
    if (_disposed) return;
    _disposed = true;
    _subscription.cancel();
    for (final waiting in _waiting.values) {
      if (!waiting.isCompleted) waiting.complete(_Unanswered.gone);
    }
    _waiting.clear();
    _socket.sink.close(code, reason);
    onGone();
  }
}
