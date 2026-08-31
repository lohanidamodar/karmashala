/// The Model Context Protocol, as this app speaks it: JSON-RPC 2.0 in, one
/// JSON-RPC message out, with no connection state of any kind between calls.
///
/// ## Why there is no session
///
/// Revisions `2025-03-26` through `2025-11-25` let a server mint an
/// `Mcp-Session-Id` at `initialize` and require it on every later request.
/// Revision `2026-07-28` removed the mechanism outright: every request declares
/// its own protocol version in `_meta`, and the server answers each one on its
/// own terms.
///
/// This server never mints one, on either side of that line, and that is a
/// decision about *this* app rather than a shortcut. Agent processes here come
/// and go constantly — a session ends mid-turn, a pane is killed, a CLI
/// restarts and reconnects — and a server holding per-connection state would
/// have to answer "who were you again?" for every one of those. Statelessness
/// makes the reconnect a non-event: the second request is indistinguishable
/// from the first, because there is nothing to have lost.
///
/// It does *not* mean the server is without state. The app it drives is the
/// state; what is absent is protocol state.
///
/// ## Dual-era
///
/// The spec's word for a server that serves both shapes. Which one a request
/// gets is decided by the protocol version it declares, not by guessing:
///
/// * `2026-07-28` — "modern". Per-request `_meta`, mirrored into
///   `MCP-Protocol-Version` / `Mcp-Method` / `Mcp-Name` headers that must agree
///   with the body, `server/discover`, and `resultType` on every result.
/// * `2025-11-25`, `2025-06-18`, `2025-03-26` — "legacy". An `initialize`
///   handshake, no header mirroring, no `resultType`.
/// * Nothing declared at all — legacy at `2025-03-26`, which is the fallback
///   the spec names for clients predating the version header.
///
/// Both are served because both are real: the CLIs that will call this today
/// open with `initialize`, and the revision they will move to does not.
library;

import 'dart:convert';

/// Revisions this server implements, newest first. A request declaring any of
/// them is served; anything else gets `UnsupportedProtocolVersionError`, which
/// lists these.
const List<String> kMcpSupportedVersions = <String>[
  '2026-07-28',
  '2025-11-25',
  '2025-06-18',
  '2025-03-26',
];

/// Revisions `server/discover` **offers**, newest first, so a client picking
/// the first it recognises picks the best one it will actually work on.
///
/// **This is deliberately not [kMcpSupportedVersions], and the difference is
/// one client's bug rather than a gap in this server.** Measured 2026-08-31
/// against Claude Code 2.1.251, which is the CLI most of this app's sessions
/// run: it probes `server/discover`, reads this field, selects `2026-07-28`,
/// sends a modern `tools/list`, receives all 62 tools — and then registers
/// **none of them**. The session reports the server as connected and the agent
/// has an empty tool surface, which is a worse outcome than no server at all,
/// because nothing about it looks broken.
///
/// It is the client's modern path and not this catalogue. The same run against
/// a hand-written server serving one trivial tool registers nothing either;
/// the same hand-written server, with `server/discover` answered `-32601` *or*
/// advertising only the revisions below, registers `mcp__…__ping_it` at once.
///
/// So the narrowest fix is here: `server/discover` stays implemented and
/// correct in shape, and offers the revisions a real client has been observed
/// to finish a session on. `2026-07-28` is still served to any request that
/// declares it — see [kMcpSupportedVersions] — it is simply not recommended to
/// a client that asks what to pick. **Delete this constant and point
/// `_discoverResult` back at [kMcpSupportedVersions] once a released client
/// registers tools over the modern path.**
const List<String> kMcpAdvertisedVersions = <String>[
  '2025-11-25',
  '2025-06-18',
  '2025-03-26',
];

/// The revision that carries its metadata per request rather than per session.
const String kMcpModernVersion = '2026-07-28';

/// The newest revision a client opening with `initialize` can be answered
/// with. `2026-07-28` has no `initialize`, so offering it to such a client
/// would be offering something it cannot use.
const String kMcpNewestLegacyVersion = '2025-11-25';

/// What a request that declares no version at all is taken to be, per the
/// transport spec's backwards-compatibility rule for clients older than the
/// `MCP-Protocol-Version` header.
const String kMcpUndeclaredVersion = '2025-03-26';

const String _protocolVersionMetaKey =
    'io.modelcontextprotocol/protocolVersion';
const String _serverInfoMetaKey = 'io.modelcontextprotocol/serverInfo';

/// JSON-RPC error codes, including the two the MCP spec allocates from its
/// reserved sub-range.
abstract final class McpErrorCode {
  static const int invalidRequest = -32600;
  static const int methodNotFound = -32601;
  static const int invalidParams = -32602;
  static const int internalError = -32603;

  /// The headers disagree with the body, or a required one is missing.
  static const int headerMismatch = -32020;

  /// The revision the client asked for is not one this server implements.
  static const int unsupportedProtocolVersion = -32022;
}

/// One answer, ready for whatever transport carried the request in.
///
/// [body] is null for a notification, which by JSON-RPC has no reply and by the
/// transport spec is a bare `202`.
class McpReply {
  const McpReply(this.statusCode, [this.body]);

  final int statusCode;
  final Map<String, Object?>? body;

  /// The reply serialised, or the empty string when there is nothing to send.
  String encode() => body == null ? '' : jsonEncode(body);
}

/// Runs one tool. Throws to fail it; the thrown object's message becomes the
/// text of an `isError` result, because a model can act on that and cannot act
/// on a JSON-RPC error.
typedef McpToolInvoker =
    Future<Object?> Function(
      String name,
      Map<String, dynamic> arguments,
      String? callerSessionId,
    );

/// The tool catalogue, read fresh on every `tools/list` so a server whose tools
/// depend on app state never serves a stale list.
typedef McpToolCatalogue = List<Map<String, dynamic>> Function();

/// A transport-free MCP server.
///
/// Everything that varies by HTTP — auth, `Origin`, method, path — belongs to
/// the endpoint that wraps this. What is here is the protocol and nothing else,
/// which is what makes the era rules testable without a socket.
class McpServer {
  McpServer({
    required this.name,
    required this.version,
    required this.catalogue,
    required this.invoke,
    this.instructions,
  });

  final String name;
  final String version;
  final String? instructions;

  /// Re-read on every listing, so a catalogue that depends on app state is
  /// never served from a snapshot taken at start-up.
  final McpToolCatalogue catalogue;
  final McpToolInvoker invoke;

  /// Answers one JSON-RPC message.
  ///
  /// [headers] must already be lower-cased; HTTP field names are
  /// case-insensitive and every comparison below assumes that has been done.
  /// [callerSessionId] is the session the transport authenticated as the
  /// caller — never anything the message said about itself.
  Future<McpReply> handle(
    Object? message, {
    Map<String, String> headers = const <String, String>{},
    String? callerSessionId,
  }) async {
    if (message is! Map<String, Object?>) {
      return _error(null, McpErrorCode.invalidRequest, 'Expected a JSON object.');
    }
    final id = message['id'];
    final method = message['method'];
    if (method is! String || method.isEmpty) {
      return _error(id, McpErrorCode.invalidRequest, 'Missing method.');
    }
    final params = switch (message['params']) {
      final Map<String, Object?> map => map,
      _ => const <String, Object?>{},
    };

    final version = _resolveVersion(params, headers, method);
    if (version.failure case final failure?) return failure(id);
    final declared = version.value;

    if (declared == kMcpModernVersion) {
      final mismatch = _validateModernHeaders(id, method, params, headers);
      if (mismatch != null) return mismatch;
    }
    final modern = declared == kMcpModernVersion;

    switch (method) {
      case 'initialize':
        // The modern revision has no handshake, so a client that reached here
        // declaring it is contradicting itself. 404 with -32601 is the answer
        // the transport spec defines for a method a server does not implement.
        if (modern) {
          return _error(
            id,
            McpErrorCode.methodNotFound,
            'initialize is not part of $kMcpModernVersion; send requests '
            'directly, or call server/discover.',
            status: 404,
          );
        }
        return _result(id, _initializeResult(params), modern: false);
      case 'notifications/initialized':
      case 'notifications/cancelled':
      case 'notifications/roots/list_changed':
        return const McpReply(202);
      case 'ping':
        return _result(id, <String, Object?>{}, modern: modern);
      case 'server/discover':
        return _result(id, _discoverResult(), modern: modern);
      case 'tools/list':
        return _result(id, <String, Object?>{
          'tools': catalogue(),
        }, modern: modern);
      case 'tools/call':
        return _callTool(id, params, callerSessionId, modern: modern);
      default:
        if (id == null) return const McpReply(202);
        return _error(
          id,
          McpErrorCode.methodNotFound,
          'Method not found: $method',
          status: modern ? 404 : 200,
        );
    }
  }

  /// Which revision this request is speaking, or the error that says why it
  /// cannot be served.
  ///
  /// The body is the source of truth and the header mirrors it, so a
  /// disagreement between them is rejected rather than resolved: a proxy
  /// routing on the header and a server executing on the body must never be
  /// looking at different requests.
  _Resolved _resolveVersion(
    Map<String, Object?> params,
    Map<String, String> headers,
    String method,
  ) {
    final meta = switch (params['_meta']) {
      final Map<String, Object?> map => map,
      _ => const <String, Object?>{},
    };
    final fromBody = meta[_protocolVersionMetaKey];
    final fromHeader = headers['mcp-protocol-version'];

    if (fromBody is String && fromBody.isNotEmpty) {
      if (fromHeader != null && fromHeader != fromBody) {
        return _Resolved.failure(
          (id) => _error(
            id,
            McpErrorCode.headerMismatch,
            'Header mismatch: MCP-Protocol-Version header value '
            "'$fromHeader' does not match body value '$fromBody'.",
            status: 400,
          ),
        );
      }
      return _supported(fromBody);
    }
    if (fromHeader != null && fromHeader.isNotEmpty) return _supported(fromHeader);
    // Nothing declared. A handshake is self-describing — its own params say
    // which revision it wants — so it is left to negotiate; anything else falls
    // back to the pre-header revision.
    return _Resolved(method == 'initialize' ? null : kMcpUndeclaredVersion);
  }

  _Resolved _supported(String version) {
    if (kMcpSupportedVersions.contains(version)) return _Resolved(version);
    return _Resolved.failure(
      (id) => _error(
        id,
        McpErrorCode.unsupportedProtocolVersion,
        'Unsupported protocol version',
        status: 400,
        data: <String, Object?>{
          'supported': kMcpSupportedVersions,
          'requested': version,
        },
      ),
    );
  }

  /// The header/body agreement the modern revision requires.
  ///
  /// Missing counts as mismatched: the spec lists "a required standard header
  /// is missing" among the conditions for `-32020`, and a server that quietly
  /// accepted the body alone would be the exact split-source-of-truth the rule
  /// exists to prevent.
  McpReply? _validateModernHeaders(
    Object? id,
    String method,
    Map<String, Object?> params,
    Map<String, String> headers,
  ) {
    if (headers['mcp-protocol-version'] == null) {
      return _error(
        id,
        McpErrorCode.headerMismatch,
        'Header mismatch: the MCP-Protocol-Version header is required by '
        '$kMcpModernVersion and was not sent.',
        status: 400,
      );
    }
    final declaredMethod = headers['mcp-method'];
    if (declaredMethod == null) {
      return _error(
        id,
        McpErrorCode.headerMismatch,
        'Header mismatch: the Mcp-Method header is required and was not sent.',
        status: 400,
      );
    }
    if (declaredMethod != method) {
      return _error(
        id,
        McpErrorCode.headerMismatch,
        "Header mismatch: Mcp-Method header value '$declaredMethod' does not "
        "match body value '$method'.",
        status: 400,
      );
    }
    final bodyName = switch (method) {
      'tools/call' || 'prompts/get' => params['name'],
      'resources/read' => params['uri'],
      _ => null,
    };
    if (bodyName is! String) return null;
    final headerName = decodeMcpHeaderValue(headers['mcp-name']);
    if (headerName == null) {
      return _error(
        id,
        McpErrorCode.headerMismatch,
        'Header mismatch: the Mcp-Name header is required for $method and was '
        'not sent.',
        status: 400,
      );
    }
    if (headerName != bodyName) {
      return _error(
        id,
        McpErrorCode.headerMismatch,
        "Header mismatch: Mcp-Name header value '$headerName' does not match "
        "body value '$bodyName'.",
        status: 400,
      );
    }
    return null;
  }

  Map<String, Object?> _initializeResult(Map<String, Object?> params) {
    final asked = params['protocolVersion'];
    // Echo what was asked for when we speak it; otherwise name the newest
    // revision that still has a handshake. Answering a legacy client with
    // 2026-07-28 would be answering it with something it cannot use.
    final agreed = asked is String && kMcpSupportedVersions.contains(asked)
        ? asked
        : kMcpNewestLegacyVersion;
    return <String, Object?>{
      'protocolVersion': agreed,
      'capabilities': <String, Object?>{'tools': <String, Object?>{}},
      'serverInfo': <String, Object?>{'name': name, 'version': version},
      'instructions': ?instructions,
    };
  }

  Map<String, Object?> _discoverResult() => <String, Object?>{
    // Advertised, not supported — see [kMcpAdvertisedVersions] for the
    // measurement that separates the two.
    'supportedVersions': kMcpAdvertisedVersions,
    'capabilities': <String, Object?>{'tools': <String, Object?>{}},
    '_meta': <String, Object?>{
      _serverInfoMetaKey: <String, Object?>{'name': name, 'version': version},
    },
    'instructions': ?instructions,
  };

  Future<McpReply> _callTool(
    Object? id,
    Map<String, Object?> params,
    String? callerSessionId, {
    required bool modern,
  }) async {
    final toolName = params['name'];
    if (toolName is! String || toolName.isEmpty) {
      return _error(id, McpErrorCode.invalidParams, 'Missing tool name.');
    }
    final known = catalogue().any((tool) => tool['name'] == toolName);
    if (!known) {
      // A protocol error, not an `isError` result: the spec puts "unknown tool"
      // in the class a model cannot fix by rewording its arguments.
      return _error(
        id,
        McpErrorCode.invalidParams,
        'Unknown tool: $toolName',
      );
    }
    final arguments = switch (params['arguments']) {
      final Map<Object?, Object?> map => map.cast<String, dynamic>(),
      _ => <String, dynamic>{},
    };

    try {
      final result = await invoke(toolName, arguments, callerSessionId);
      return _result(
        id,
        _toolResult(toolName, result),
        modern: modern,
      );
    } on Object catch (error) {
      // Tool failures come back as results, so the model reads them and can
      // correct itself. An empty success would be the one unacceptable answer:
      // it reads as "done" for something that did not happen.
      return _result(
        id,
        <String, Object?>{
          'content': <Object?>[
            <String, Object?>{'type': 'text', 'text': 'Error: $error'},
          ],
          'isError': true,
        },
        modern: modern,
      );
    }
  }

  /// Shapes one tool's return value as a `CallToolResult`.
  ///
  /// A tool that declared an `outputSchema` **must** return structured results,
  /// so `structuredContent` is emitted for exactly those and the JSON goes in a
  /// text block beside it — which is also what a client that ignores structured
  /// content needs in order to see anything at all.
  Map<String, Object?> _toolResult(String toolName, Object? result) {
    // A tool returning content blocks of its own — an image, say — hands them
    // back under `_mcpContent` to be passed through untouched.
    if (result is Map && result['_mcpContent'] is List) {
      return <String, Object?>{'content': result['_mcpContent']};
    }
    final text = const JsonEncoder.withIndent('  ').convert(result);
    final declaresOutput = catalogue().any(
      (tool) => tool['name'] == toolName && tool['outputSchema'] != null,
    );
    return <String, Object?>{
      'content': <Object?>[
        <String, Object?>{'type': 'text', 'text': text},
      ],
      if (declaresOutput && (result is Map || result is List))
        'structuredContent': result,
      'isError': false,
    };
  }

  McpReply _result(Object? id, Map<String, Object?> result, {required bool modern}) {
    if (id == null) return const McpReply(202);
    return McpReply(200, <String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'result': <String, Object?>{
        // `resultType` arrived with the modern revision; sending it to a legacy
        // client would be sending it a field its schema does not have.
        if (modern) 'resultType': 'complete',
        ...result,
      },
    });
  }

  McpReply _error(
    Object? id,
    int code,
    String message, {
    int status = 200,
    Map<String, Object?>? data,
  }) => McpReply(status, <String, Object?>{
    'jsonrpc': '2.0',
    // A protocol fault with no id still gets a body; the spec allows an error
    // response with a null id precisely for the requests that never parsed.
    'id': id,
    'error': <String, Object?>{
      'code': code,
      'message': message,
      'data': ?data,
    },
  });
}

/// Undoes the `=?base64?…?=` sentinel clients use for header values that cannot
/// be written as plain ASCII. Returns [raw] unchanged when it is not encoded,
/// and null when there was no header.
String? decodeMcpHeaderValue(String? raw) {
  if (raw == null) return null;
  const prefix = '=?base64?';
  const suffix = '?=';
  if (!raw.startsWith(prefix) || !raw.endsWith(suffix)) return raw;
  final payload = raw.substring(prefix.length, raw.length - suffix.length);
  try {
    return utf8.decode(base64.decode(payload));
  } on Object {
    // A malformed sentinel is not a value; leaving it as-is makes it fail the
    // comparison it was about to be used for, which is the right outcome.
    return raw;
  }
}

/// Either a resolved protocol version or the reply that refuses the request.
class _Resolved {
  const _Resolved(this.value) : failure = null;
  const _Resolved.failure(this.failure) : value = null;

  final String? value;
  final McpReply Function(Object? id)? failure;
}
