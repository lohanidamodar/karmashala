import 'dart:convert';
import 'dart:io';

import '../../core/logging/app_logger.dart';
import 'mcp_caller_registry.dart';
import 'mcp_protocol.dart';

/// The Streamable HTTP binding: one path, POST only, no session.
///
/// ## Why loopback, given the threat model next door
///
/// `LauncherControlServer`'s class doc argues at length that loopback TCP is
/// not an access-control decision — it has no peer credentials, so any process
/// on the box, running as any user, can open the port — and that is why
/// privileged `/rpc` lives on a unix socket in an owner-only directory instead.
///
/// This endpoint is on loopback anyway, for the reason that doc already gives
/// for `/agent-hook`: **an MCP client dials an `http://` URL.** It cannot dial
/// a socket path, and an agent running in WSL or over SSH could not name a
/// Windows one even if its client could. There is no transport that is both
/// reachable by a real MCP client and stronger than this.
///
/// So the boundary is what is left, and it is deliberate rather than residual:
///
/// * **A token of its own**, minted under exactly the same prerequisites as the
///   `/rpc` token. If the owner-only channel could not be established, this
///   endpoint has no credential and answers `401` to everything — the same
///   fail-closed rule, not a hole beside it.
/// * **`Origin` validation.** This is the mitigation that actually earns its
///   place: the realistic attack on a loopback service is a page in the user's
///   own browser reaching it by DNS rebinding, and that is exactly the attack
///   a unix socket would not have prevented either. A present `Origin` that is
///   not loopback gets `403`, as the spec requires.
/// * **`127.0.0.1` only**, never `0.0.0.0`.
class McpHttpEndpoint {
  McpHttpEndpoint({
    required this.server,
    required this.callers,
    AppLogger? logger,
  }) : _logger = logger ?? AppLogger.named('mcp-http');

  /// The single MCP endpoint. A caller identifies itself by appending its
  /// credential — `/mcp/<token>` — so the whole handshake is one URL.
  static const String path = '/mcp';

  static const int _maxRequestBytes = 1024 * 1024;

  final McpServer server;
  final McpCallerRegistry callers;
  final AppLogger _logger;

  /// The credential this endpoint accepts from a caller with no session of its
  /// own. Null means no privileged credential was minted, and nothing is served.
  String? token;

  /// Whether [uri] is for this endpoint at all.
  static bool handles(Uri uri) =>
      uri.path == path || uri.path.startsWith('$path/');

  Future<void> handle(HttpRequest request) async {
    final response = request.response;
    try {
      // Origin first: a rejected origin must not reach auth, so a rebinding
      // attempt learns nothing about whether its guessed token was right.
      final origin = request.headers.value('origin');
      if (!_originAllowed(origin)) {
        _logger.warning('Refused an MCP request from origin $origin.');
        await _send(
          response,
          const McpReply(HttpStatus.forbidden, <String, Object?>{
            'jsonrpc': '2.0',
            'id': null,
            'error': <String, Object?>{
              'code': McpErrorCode.invalidRequest,
              'message':
                  'Forbidden origin. This endpoint serves local agents only.',
            },
          }),
        );
        return;
      }

      // GET was the standalone SSE stream and DELETE ended a session; the
      // current revision removed both, and the spec names 405 as the answer.
      if (request.method != 'POST') {
        response.statusCode = HttpStatus.methodNotAllowed;
        response.headers.set(HttpHeaders.allowHeader, 'POST');
        await response.close();
        return;
      }

      final caller = _authenticate(request);
      if (!caller.authenticated) {
        response.statusCode = HttpStatus.unauthorized;
        await response.close();
        return;
      }

      final body = await _readBoundedBody(request);
      Object? decoded;
      try {
        decoded = jsonDecode(body);
      } on FormatException catch (error) {
        await _send(
          response,
          McpReply(HttpStatus.badRequest, <String, Object?>{
            'jsonrpc': '2.0',
            'id': null,
            'error': <String, Object?>{
              'code': McpErrorCode.invalidRequest,
              'message': 'Malformed JSON: ${error.message}',
            },
          }),
        );
        return;
      }

      final reply = await server.handle(
        decoded,
        headers: _headersOf(request),
        callerSessionId: caller.sessionId,
      );
      await _send(response, reply);
    } on Object catch (error, stack) {
      _logger.warning('An MCP request failed.', error, stack);
      try {
        await _send(
          response,
          McpReply(HttpStatus.internalServerError, <String, Object?>{
            'jsonrpc': '2.0',
            'id': null,
            'error': <String, Object?>{
              'code': McpErrorCode.internalError,
              'message': '$error',
            },
          }),
        );
      } on Object {
        // The response was already committed. Nothing further to say.
      }
    }
  }

  /// Who is calling, from the credential they presented.
  ///
  /// The path segment is the primary carrier and `Authorization: Bearer` the
  /// fallback, because some clients are easier to configure one way than the
  /// other — but they are the *same* credential space, so there is one rule
  /// about what a token means and not two.
  _Caller _authenticate(HttpRequest request) {
    final live = token;
    // No credential exists, so no caller can present one. Without this an
    // interpolated `Bearer null` would be a header anyone could send.
    if (live == null) return const _Caller.rejected();

    final segments = request.uri.pathSegments;
    final fromPath = segments.length > 1 ? segments[1] : null;
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    final fromHeader = header != null && header.startsWith('Bearer ')
        ? header.substring('Bearer '.length)
        : null;

    for (final presented in <String?>[fromPath, fromHeader]) {
      if (presented == null || presented.isEmpty) continue;
      if (constantTimeEquals(presented, live)) {
        // The server token names no session: the launcher, or a bridge started
        // by hand. Unattributed, and treated as root.
        return const _Caller(authenticated: true);
      }
      if (callers.sessionFor(presented) case final sessionId?) {
        return _Caller(authenticated: true, sessionId: sessionId);
      }
    }
    return const _Caller.rejected();
  }

  /// Whether a browser-set `Origin` may drive this server.
  ///
  /// Absent is fine — an agent CLI is not a browser and sends none. Present and
  /// loopback is fine. Present and anything else, `null` included, is a page,
  /// and a page has no business here: `null` is the opaque origin a sandboxed
  /// frame or a `file://` document sends, which is a browser context that has
  /// deliberately hidden where it came from.
  static bool _originAllowed(String? origin) {
    if (origin == null) return true;
    final uri = Uri.tryParse(origin);
    if (uri == null) return false;
    return uri.host == '127.0.0.1' ||
        uri.host == 'localhost' ||
        uri.host == '::1' ||
        uri.host == '[::1]';
  }

  /// Request headers, lower-cased, one value each.
  ///
  /// `HttpHeaders` already lower-cases field names; the protocol layer relies
  /// on that and this is where it is made true rather than assumed.
  static Map<String, String> _headersOf(HttpRequest request) {
    final headers = <String, String>{};
    request.headers.forEach((name, values) {
      if (values.isNotEmpty) headers[name.toLowerCase()] = values.first;
    });
    return headers;
  }

  Future<String> _readBoundedBody(HttpRequest request) async {
    if (request.contentLength > _maxRequestBytes) {
      throw const FormatException('Request body exceeds the 1 MiB limit.');
    }
    final bytes = <int>[];
    await for (final chunk in request) {
      bytes.addAll(chunk);
      if (bytes.length > _maxRequestBytes) {
        throw const FormatException('Request body exceeds the 1 MiB limit.');
      }
    }
    return utf8.decode(bytes);
  }

  Future<void> _send(HttpResponse response, McpReply reply) async {
    response.statusCode = reply.statusCode;
    if (reply.body != null) {
      response.headers.contentType = ContentType.json;
      response.write(reply.encode());
    }
    await response.close();
  }
}

class _Caller {
  const _Caller({required this.authenticated, this.sessionId});
  const _Caller.rejected() : authenticated = false, sessionId = null;

  final bool authenticated;

  /// The session the credential named, or null for an unattributed caller.
  final String? sessionId;
}
