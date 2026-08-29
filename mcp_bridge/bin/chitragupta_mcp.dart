// Chitragupta MCP bridge.
//
// A tiny, standalone Model Context Protocol server (JSON-RPC 2.0 over stdio)
// that a coding-agent CLI (e.g. Claude Code) spawns. It carries no database,
// Flutter, or plugin dependencies: every tool call is forwarded over loopback
// HTTP to the running Chitragupta app's launcher control server, whose address
// and bearer token it reads from `mcp_bridge.json`.
//
// Usage (configured via the agent's --mcp-config): the command is this program
// (compiled, or `dart run bin/chitragupta_mcp.dart`). It speaks MCP on stdio.
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final bridge = _Bridge();
  final lines = stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter());
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
          {'type': 'text', 'text': const JsonEncoder.withIndent('  ').convert(result)},
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
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${config.port}/rpc'),
      );
      request.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer ${config.token}')
        ..contentType = ContentType.json;
      request.write(jsonEncode({'tool': tool, 'arguments': arguments}));
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

  Future<_BridgeConfig> _loadConfig() async {
    // Re-read each time it's missing/stale so a restarted app (new port) is
    // picked up without restarting the bridge.
    final existing = _config;
    if (existing != null) return existing;
    final appData = Platform.environment['APPDATA'];
    if (appData == null) {
      throw StateError('APPDATA is not set; cannot locate mcp_bridge.json.');
    }
    final file = File(
      '$appData\\com.popupbits\\chitragupta\\mcp_bridge.json',
    );
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
  _BridgeConfig({required this.port, required this.token});
  final int port;
  final String token;
}
