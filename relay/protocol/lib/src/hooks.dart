/// Webhooks through the relay: a server keeps a listener open at
/// `v1/hooks/<listen key>`, a caller posts to `h/<listen id>/<hook id>`, and
/// the relay forwards the call to that listener as one frame and returns its
/// answer. The relay judges nothing but shape, size and rate; the server
/// verifies everything else.
library;

import 'dart:convert';

import 'routes.dart';

/// The segment after `v1/` that names the listener route.
const String kHooksListenSegment = 'hooks';

/// The first segment of a call: `h/<listen id>/<hook id>`.
const String kHookCallSegment = 'h';

/// A listen key: 64 lowercase hex characters (32 bytes), known only to the
/// server it belongs to. The relay never stores or logs it.
final RegExp hooksListenKeyPattern = RegExp(r'^[0-9a-f]{64}$');

/// A listen id: 32 lowercase hex characters — the first 16 bytes of
/// SHA-256 over the ASCII of `karmashala-hooks-listen:<listen key>`. Public:
/// it is in every hook URL, and knowing it does not let anyone listen.
final RegExp hooksListenIdPattern = RegExp(r'^[0-9a-f]{32}$');

/// What the relay hashes to turn a listen key into its listen id.
String hooksListenIdInput(String listenKey) =>
    'karmashala-hooks-listen:$listenKey';

/// A known answer every implementation of the derivation is tested against.
const ({String key, String id}) kHooksListenIdVector = (
  key: '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
  id: '7d1ab47671cbb7762c8b92a35733f9a1',
);

/// A hook id: 32 lowercase hex characters (128 random bits).
final RegExp hookIdPattern = RegExp(r'^[0-9a-f]{32}$');

final RegExp _listenPathPattern = RegExp(
  '^$kRelayApiVersion/$kHooksListenSegment/([0-9a-f]{64})\$',
);

final RegExp _callPathPattern = RegExp(
  '^$kHookCallSegment/([0-9a-f]{32})/([0-9a-f]{32})\$',
);

/// The listener route for [listenKey], without a leading slash.
String hooksListenPath(String listenKey) =>
    '$kRelayApiVersion/$kHooksListenSegment/$listenKey';

/// The call route for a hook, without a leading slash.
String hookCallPath(String listenId, String hookId) =>
    '$kHookCallSegment/$listenId/$hookId';

/// The listen key [path] presents, or null when it is not the listener route.
String? hooksListenKeyOf(String path) =>
    _listenPathPattern.firstMatch(path)?.group(1);

/// Whether [path] is under the call route at all, well formed or not — so a
/// malformed hook URL is a 404 from the hooks code, never a rendezvous.
bool isHookCallRoute(String path) =>
    path == kHookCallSegment || path.startsWith('$kHookCallSegment/');

/// The listen id and hook id [path] names, or null when it names none.
({String listenId, String hookId})? hookCallOf(String path) {
  final match = _callPathPattern.firstMatch(path);
  if (match == null) return null;
  return (listenId: match.group(1)!, hookId: match.group(2)!);
}

/// The request headers a call carries to the server, lowercase. Nothing else
/// is forwarded: no cookies, no authorization, no forwarding chain.
const List<String> kHookForwardedHeaders = [
  'content-type',
  'user-agent',
  'x-hub-signature-256',
  'x-github-delivery',
  'x-github-event',
  'x-karmashala-signature',
  'x-karmashala-timestamp',
  'x-karmashala-delivery',
  'x-request-id',
];

/// Longest header value forwarded; a longer one is cut to this.
const int kHookMaxHeaderValue = 1024;

/// Largest call body the relay forwards.
const int kHookMaxBodyBytes = 256 * 1024;

/// Largest answer body the relay returns; a larger one is a bad answer.
const int kHookMaxAnswerBytes = 4096;

/// How long the relay waits for the server's answer.
const Duration kHookAnswerTimeout = Duration(seconds: 10);

/// Calls one listen id may receive a minute, and the burst it may spend.
const int kDefaultHookCallsPerMinute = 60;

/// Calls one listener may have waiting on an answer at once.
const int kHookMaxInFlight = 16;

/// The version of the listener frames, sent in [HooksReady].
const int kHooksProtocolVersion = 1;

/// The HTTP statuses a call can be answered with. The relay's own are
/// [methodNotAllowed], [notFound], [tooLarge], [slowDown], [badAnswer],
/// [serverOffline] and [timedOut]; the rest come from the server.
abstract final class HookStatus {
  static const int accepted = 202;
  static const int badSignature = 401;

  /// An unknown hook and a disabled one answer the same.
  static const int notFound = 404;
  static const int methodNotAllowed = 405;
  static const int replay = 409;
  static const int tooLarge = 413;
  static const int badPayload = 422;
  static const int slowDown = 429;
  static const int failed = 500;

  /// The server's answer frame broke the contract.
  static const int badAnswer = 502;

  /// No listener holds this listen id.
  static const int serverOffline = 503;

  /// The listener did not answer within [kHookAnswerTimeout].
  static const int timedOut = 504;
}

/// The JSON body the relay itself answers with: `{"error": "<words>"}`.
String hookErrorBody(String words) => jsonEncode({'error': words});

/// A frame on the listener socket. Every frame is one JSON text message with
/// a `type`; an unknown type is ignored by both ends, so either can grow.
sealed class HookFrame {
  const HookFrame();

  Map<String, Object?> toJson();

  String encode() => jsonEncode(toJson());

  /// The frame [text] carries, or null for anything this build cannot read.
  static HookFrame? tryDecode(Object? text) {
    if (text is! String) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?>) return null;
    return switch (decoded['type']) {
      HooksReady.type => HooksReady.tryParse(decoded),
      HookCall.type => HookCall.tryParse(decoded),
      HookAnswer.type => HookAnswer.tryParse(decoded),
      _ => null,
    };
  }
}

/// Relay → server, once, when the listener is accepted.
final class HooksReady extends HookFrame {
  const HooksReady({
    required this.listenId,
    this.version = kHooksProtocolVersion,
    this.maxBodyBytes = kHookMaxBodyBytes,
    this.timeoutMs = 10000,
  });

  static const String type = 'ready';

  final String listenId;
  final int version;
  final int maxBodyBytes;
  final int timeoutMs;

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'listen': listenId,
    'v': version,
    'maxBody': maxBodyBytes,
    'timeoutMs': timeoutMs,
  };

  static HooksReady? tryParse(Map<String, Object?> json) {
    final listen = json['listen'];
    final v = json['v'];
    if (listen is! String || !hooksListenIdPattern.hasMatch(listen)) {
      return null;
    }
    if (v is! int) return null;
    final maxBody = json['maxBody'];
    final timeout = json['timeoutMs'];
    return HooksReady(
      listenId: listen,
      version: v,
      maxBodyBytes: maxBody is int ? maxBody : kHookMaxBodyBytes,
      timeoutMs: timeout is int ? timeout : 10000,
    );
  }
}

/// Relay → server: one call, with the chosen headers and the raw body.
final class HookCall extends HookFrame {
  const HookCall({
    required this.id,
    required this.hookId,
    required this.method,
    required this.headers,
    required this.body,
    this.ip = '',
  });

  static const String type = 'call';

  /// The relay's own id for this call, echoed in the answer.
  final String id;
  final String hookId;
  final String method;

  /// Lowercase names from [kHookForwardedHeaders] only.
  final Map<String, String> headers;

  /// The raw body, byte for byte — a signature is over these bytes.
  final List<int> body;

  /// The caller's address as the relay saw it; empty when it could not say.
  final String ip;

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'id': id,
    'hook': hookId,
    'method': method,
    'headers': headers,
    'ip': ip,
    'body': base64Encode(body),
  };

  static HookCall? tryParse(Map<String, Object?> json) {
    final id = json['id'];
    final hook = json['hook'];
    final method = json['method'];
    final headers = json['headers'];
    final body = json['body'];
    final ip = json['ip'];
    if (id is! String || id.isEmpty || id.length > 128) return null;
    if (hook is! String || !hookIdPattern.hasMatch(hook)) return null;
    if (method is! String || headers is! Map || body is! String) return null;
    final List<int> bytes;
    try {
      bytes = base64Decode(body);
    } on FormatException {
      return null;
    }
    return HookCall(
      id: id,
      hookId: hook,
      method: method,
      headers: {
        for (final MapEntry(:key, :value) in headers.entries)
          if (key is String &&
              value is String &&
              kHookForwardedHeaders.contains(key))
            key: value,
      },
      body: bytes,
      ip: ip is String ? ip : '',
    );
  }
}

/// Server → relay: the answer to call [id].
final class HookAnswer extends HookFrame {
  const HookAnswer({
    required this.id,
    required this.status,
    this.body = const {},
  });

  static const String type = 'answer';

  final String id;
  final int status;

  /// Small JSON the relay returns verbatim; never more than
  /// [kHookMaxAnswerBytes] encoded.
  final Map<String, Object?> body;

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'id': id,
    'status': status,
    'body': body,
  };

  /// Null when the answer breaks a rule — which the relay answers
  /// [HookStatus.badAnswer].
  static HookAnswer? tryParse(Map<String, Object?> json) {
    final id = json['id'];
    final status = json['status'];
    final body = json['body'];
    if (id is! String || status is! int) return null;
    if (status < 200 || status > 599) return null;
    if (body is! Map<String, Object?>) return null;
    if (utf8.encode(jsonEncode(body)).length > kHookMaxAnswerBytes) return null;
    return HookAnswer(id: id, status: status, body: body);
  }
}
