import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../protocol/messages.dart';
import 'hook_endpoint_file.dart';

/// The header a hook names its pane's `KARMASHALA_SESSION_ID` in. Must equal
/// the app's `kPaneSessionHeader`, which writes the scripts that send it.
const String kHookSessionHeader = 'X-Karmashala-Session';

/// The most one hook payload may be; the scripts cut at the same number.
const int kHookPayloadLimitBytes = 1024 * 1024;

/// A loopback HTTP listener taking `POST /agent-hook?agent=<id>&event=<name>`
/// with a bearer token. Answers exactly as the app's route did, so a script's
/// unauthenticated probe still reads `401` and proves the port is ours — and,
/// like it, not before `onHook` completes: that is how a tool is held.
class HookServer {
  HookServer._(this._server, this.token, this._onHook, this._now) {
    _server.listen((request) => unawaited(_handle(request)));
  }

  /// Binds [port] (0 for any), falling back to any free port when [port] is
  /// taken. The token is reused when given, else minted.
  static Future<HookServer> bind({
    required FutureOr<void> Function(AgentHookEvent hook) onHook,
    int port = 0,
    String? token,
    DateTime Function()? clock,
  }) async {
    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    } on SocketException {
      if (port == 0) rethrow;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    }
    return HookServer._(
      server,
      token ?? _mintToken(),
      onHook,
      clock ?? () => DateTime.now().toUtc(),
    );
  }

  final HttpServer _server;
  final String token;
  final FutureOr<void> Function(AgentHookEvent hook) _onHook;
  final DateTime Function() _now;

  int get port => _server.port;

  HookEndpoint get endpoint => HookEndpoint(port: port, token: token);

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.uri.path != kAgentHookPath) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      if (!_constantTimeEquals(
        request.headers.value(HttpHeaders.authorizationHeader),
        'Bearer $token',
      )) {
        response.statusCode = HttpStatus.unauthorized;
        return;
      }
      if (request.method != 'POST') {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      final body = await _readBoundedBody(request);
      final decoded = _decodeObject(body);
      // Not JSON is nothing any agent reader could use; still 200, because a
      // hook must never fail the agent that fired it.
      if (decoded != null) {
        final pane = request.headers.value(kHookSessionHeader)?.trim();
        await _onHook(
          AgentHookEvent(
            agent: request.uri.queryParameters['agent'] ?? '',
            event: request.uri.queryParameters['event'] ?? '',
            sessionHeader: pane == null || pane.isEmpty ? null : pane,
            receivedAt: _now(),
            body: decoded,
          ),
        );
      }
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode({'ok': true}));
    } on Object {
      response.statusCode = HttpStatus.internalServerError;
    } finally {
      try {
        await response.close();
      } on Object {
        // The agent's curl gave up first; nothing is owed to it.
      }
    }
  }

  static Future<String> _readBoundedBody(HttpRequest request) async {
    if (request.contentLength > kHookPayloadLimitBytes) {
      throw const FormatException('hook body over the limit');
    }
    final bytes = <int>[];
    await for (final chunk in request) {
      bytes.addAll(chunk);
      if (bytes.length > kHookPayloadLimitBytes) {
        throw const FormatException('hook body over the limit');
      }
    }
    return utf8.decode(bytes);
  }

  static Map<String, Object?>? _decodeObject(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  /// 24 bytes from the platform CSPRNG: the token is the whole boundary.
  static String _mintToken() {
    final random = Random.secure();
    return base64Url.encode(List<int>.generate(24, (_) => random.nextInt(256)));
  }

  static bool _constantTimeEquals(String? actual, String expected) {
    if (actual == null || actual.length != expected.length) return false;
    var diff = 0;
    for (var i = 0; i < expected.length; i++) {
      diff |= actual.codeUnitAt(i) ^ expected.codeUnitAt(i);
    }
    return diff == 0;
  }
}
