// Chitragupta MCP bridge.
//
// A tiny, standalone Model Context Protocol server (JSON-RPC 2.0 over stdio)
// that a coding-agent CLI (e.g. Claude Code) spawns. It carries no database,
// Flutter, or plugin dependencies: every tool call is forwarded to the running
// Chitragupta app's launcher control server, whose address and bearer token it
// reads from `mcp_bridge.json`.
//
// Transport: an owner-only unix domain socket when the handshake names one
// (which the app always does), falling back to authenticated loopback HTTP
// only when it does not — a test server, or an app that could not bind its
// socket.
//
// Usage (configured via the agent's --mcp-config): the command is this program
// (compiled, or `dart run bin/chitragupta_mcp.dart`). It speaks MCP on stdio.
import 'dart:convert';
import 'dart:io';

import 'package:chitragupta_local_ipc/chitragupta_local_ipc.dart';

Future<void> main(List<String> args) async {
  final bridge = _Bridge();
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    Map<String, dynamic> message;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, dynamic>) continue;
      message = decoded;
    } catch (_) {
      continue;
    }
    await bridge.handle(message);
  }
}

class _Bridge {
  _BridgeConfig? _config;

  Future<void> handle(Map<String, dynamic> message) async {
    final method = message['method'] as String?;
    final id = message['id'];
    // Notifications (no id) never get a response.
    switch (method) {
      case 'initialize':
        _reply(id, {
          'protocolVersion': '2024-11-05',
          'capabilities': {'tools': <String, dynamic>{}},
          'serverInfo': {'name': 'chitragupta', 'version': '1.0.0'},
        });
      case 'notifications/initialized':
        break; // no response
      case 'ping':
        _reply(id, <String, dynamic>{});
      case 'tools/list':
        await _toolsList(id);
      case 'tools/call':
        await _toolsCall(id, message['params']);
      default:
        if (id != null) {
          _error(id, -32601, 'Method not found: $method');
        }
    }
  }

  Future<void> _toolsList(Object? id) async {
    try {
      final result = await _call('__list_tools__', const {});
      _reply(id, {'tools': result});
    } catch (e) {
      _error(id, -32603, 'Could not list tools: $e');
    }
  }

  Future<void> _toolsCall(Object? id, Object? params) async {
    if (params is! Map) {
      _error(id, -32602, 'Invalid params');
      return;
    }
    final name = params['name'] as String?;
    final arguments =
        (params['arguments'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    if (name == null) {
      _error(id, -32602, 'Missing tool name');
      return;
    }
    try {
      final result = await _call(name, arguments);
      // A tool that needs to return something other than text (an image, say)
      // hands back `_mcpContent`: MCP content blocks to pass through verbatim.
      // Everything else is JSON-encoded as text, as before.
      if (result is Map && result['_mcpContent'] is List) {
        _reply(id, {'content': result['_mcpContent']});
        return;
      }
      _reply(id, {
        'content': [
          {
            'type': 'text',
            'text': const JsonEncoder.withIndent('  ').convert(result),
          },
        ],
      });
    } catch (e) {
      // Report tool failures as tool results (isError) so the model can react,
      // per the MCP convention, rather than as protocol errors.
      _reply(id, {
        'content': [
          {'type': 'text', 'text': 'Error: $e'},
        ],
        'isError': true,
      });
    }
  }

  /// Forwards a tool call to the app's control server over loopback HTTP.
  Future<Object?> _call(String tool, Map<String, dynamic> arguments) async {
    final config = await _loadConfig();
    final payload = _payloadFor(tool, arguments, config);
    if (config.socketPath case final socketPath?) {
      String raw;
      try {
        raw = await LocalRpcClient.call(socketPath, payload);
      } on Object {
        // The app may have restarted while this long-lived bridge stayed up.
        // Re-read the handshake once so a moved socket is picked up.
        _config = null;
        final fresh = await _loadConfig();
        final freshSocket = fresh.socketPath;
        if (freshSocket == null) rethrow;
        raw = await LocalRpcClient.call(
          freshSocket,
          _payloadFor(tool, arguments, fresh),
        );
      }
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded['ok'] == true) return decoded['result'];
      final error = decoded is Map ? decoded['error'] : 'unknown error';
      throw StateError('$error');
    }
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${config.port}/rpc'),
      );
      request.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer ${config.token}')
        ..contentType = ContentType.json;
      request.write(payload);
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['ok'] == true) return decoded['result'];
      final error = decoded is Map ? decoded['error'] : 'unknown error';
      throw StateError('$error');
    } finally {
      client.close(force: true);
    }
  }

  /// The request body for one tool call.
  ///
  /// `callerSessionId` says which Chitragupta session this bridge is running
  /// inside, when it is running inside one. Chitragupta stamps
  /// CHITRAGUPTA_SESSION_ID on the agent process when it opens an agent pane;
  /// this bridge is that agent's own child, so it inherits it. Forwarding it is
  /// what lets the app cap how deep agents may spawn agents — read off the real
  /// process tree rather than declared by the caller, which could simply omit
  /// it. Absent for the launcher chat and for a bridge started by hand, which
  /// are then treated as root.
  ///
  /// The token goes in the body rather than a header because the socket
  /// transport has no headers; over HTTP it is sent as a bearer header instead.
  String _payloadFor(
    String tool,
    Map<String, dynamic> arguments,
    _BridgeConfig config,
  ) {
    final callerSessionId = Platform.environment['CHITRAGUPTA_SESSION_ID'];
    return jsonEncode({
      'tool': tool,
      'arguments': arguments,
      'token': config.token,
      if (callerSessionId != null && callerSessionId.isNotEmpty)
        'callerSessionId': callerSessionId,
    });
  }

  Future<_BridgeConfig> _loadConfig() async {
    // Re-read each time it's missing/stale so a restarted app (new port) is
    // picked up without restarting the bridge.
    final existing = _config;
    if (existing != null) return existing;
    final file = File(_handshakePath());
    if (!await file.exists()) {
      throw StateError(
        'Chitragupta is not running (mcp_bridge.json not found). '
        'Open the app, then retry.',
      );
    }
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final config = _BridgeConfig(
      port: json['port'] as int,
      token: json['token'] as String,
      socketPath: json['socketPath'] as String?,
    );
    _config = config;
    return config;
  }

  void _reply(Object? id, Object? result) {
    if (id == null) return;
    _send({'jsonrpc': '2.0', 'id': id, 'result': result});
  }

  void _error(Object? id, int code, String message) {
    _send({
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': code, 'message': message},
    });
  }

  void _send(Map<String, dynamic> message) {
    stdout.writeln(jsonEncode(message));
  }
}

class _BridgeConfig {
  _BridgeConfig({required this.port, required this.token, this.socketPath});
  final int port;
  final String token;

  /// The owner-only RPC socket, when the app published one.
  final String? socketPath;
}

/// Where the app publishes `mcp_bridge.json`.
///
/// Mirrors `path_provider`'s application-support directory per platform, and is
/// overridable so a bridge can be pointed at a second install (or a test app)
/// without guessing.
String _handshakePath() {
  final override = Platform.environment['CHITRAGUPTA_BRIDGE_HANDSHAKE'];
  if (override != null && override.isNotEmpty) return override;
  if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA'];
    if (appData == null) {
      throw StateError('APPDATA is not set; cannot locate mcp_bridge.json.');
    }
    return '$appData\\com.popupbits\\chitragupta\\mcp_bridge.json';
  }
  final home = Platform.environment['HOME'];
  if (home == null) {
    throw StateError('HOME is not set; cannot locate mcp_bridge.json.');
  }
  if (Platform.isMacOS) {
    return '$home/Library/Application Support/com.popupbits.chitragupta/'
        'mcp_bridge.json';
  }
  final dataHome =
      Platform.environment['XDG_DATA_HOME'] ?? '$home/.local/share';
  return '$dataHome/com.popupbits.chitragupta/mcp_bridge.json';
}
