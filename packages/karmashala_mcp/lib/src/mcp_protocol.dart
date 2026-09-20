/// The Model Context Protocol, as this app speaks it: JSON-RPC in, one message
/// out, no session state. Dual-era, on the version a request declares.
library;

import 'dart:convert';

/// Revisions this server implements, newest first. Anything else gets
/// `UnsupportedProtocolVersionError`, which lists these.
const List<String> kMcpSupportedVersions = <String>[
  '2026-07-28',
  '2025-11-25',
  '2025-06-18',
  '2025-03-26',
];

/// Revisions `server/discover` **offers**: narrower than [kMcpSupportedVersions]
/// until a released client actually registers tools over the modern path.
const List<String> kMcpAdvertisedVersions = <String>[
  '2025-11-25',
  '2025-06-18',
  '2025-03-26',
];

/// The revision that carries its metadata per request rather than per session.
const String kMcpModernVersion = '2026-07-28';

/// The newest revision a client opening with `initialize` can be answered with;
/// `2026-07-28` has no `initialize` for it to use.
const String kMcpNewestLegacyVersion = '2025-11-25';

/// What a request that declares no version at all is taken to be, per the
/// transport spec's rule for clients older than the version header.
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

/// One answer, ready for whatever transport carried the request in. [body] is
/// null for a notification, which the transport spec answers with a bare `202`.
class McpReply {
  const McpReply(this.statusCode, [this.body]);

  final int statusCode;
  final Map<String, Object?>? body;

  /// The reply serialised, or the empty string when there is nothing to send.
  String encode() => body == null ? '' : jsonEncode(body);
}

/// Runs one tool. Throws to fail it: the thrown message becomes the text of an
/// `isError` result, which a model can act on where a JSON-RPC error is not.
typedef McpToolInvoker =
    Future<Object?> Function(
      String name,
      Map<String, dynamic> arguments,
      String? callerSessionId,
    );

/// The tool catalogue, read fresh on every `tools/list` so a server whose tools
/// depend on app state never serves a stale list.
typedef McpToolCatalogue = List<Map<String, dynamic>> Function();

/// A transport-free MCP server: everything that varies by HTTP belongs to the
/// endpoint wrapping this, which is what makes the era rules testable.
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

  /// Answers one JSON-RPC message. [headers] must already be lower-cased, and
  /// [callerSessionId] is the session the transport authenticated.
  Future<McpReply> handle(
    Object? message, {
    Map<String, String> headers = const <String, String>{},
    String? callerSessionId,
  }) async {
    if (message is! Map<String, Object?>) {
      return _error(
        null,
        McpErrorCode.invalidRequest,
        'Expected a JSON object.',
      );
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
        // declaring it is contradicting itself.
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

  /// Which revision this request is speaking, or the error saying why not. The
  /// body is the source of truth; a header that disagrees is rejected.
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
    if (fromHeader != null && fromHeader.isNotEmpty) {
      return _supported(fromHeader);
    }
    // Nothing declared. A handshake is self-describing, so it is left to
    // negotiate; anything else falls back to the pre-header revision.
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

  /// The header/body agreement the modern revision requires. Missing counts as
  /// mismatched, per the spec's own conditions for `-32020`.
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
    // Echo what was asked for when we speak it; otherwise the newest revision
    // that still has a handshake, which is all a legacy client can use.
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
      return _error(id, McpErrorCode.invalidParams, 'Unknown tool: $toolName');
    }
    final arguments = switch (params['arguments']) {
      final Map<Object?, Object?> map => map.cast<String, dynamic>(),
      _ => <String, dynamic>{},
    };

    try {
      final result = await invoke(toolName, arguments, callerSessionId);
      return _result(id, _toolResult(toolName, result), modern: modern);
    } on Object catch (error) {
      // Tool failures come back as results so the model can correct itself; an
      // empty success would read as "done" for something that did not happen.
      return _result(id, <String, Object?>{
        'content': <Object?>[
          <String, Object?>{'type': 'text', 'text': 'Error: $error'},
        ],
        'isError': true,
      }, modern: modern);
    }
  }

  /// Shapes one tool's return value as a `CallToolResult`: a tool that declared
  /// an `outputSchema` **must** return structured results, with text beside them.
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

  McpReply _result(
    Object? id,
    Map<String, Object?> result, {
    required bool modern,
  }) {
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
    'error': <String, Object?>{'code': code, 'message': message, 'data': ?data},
  });
}

/// Undoes the `=?base64?…?=` sentinel used for non-ASCII header values. Returns
/// [raw] unchanged when it is not encoded, and null when there was no header.
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
