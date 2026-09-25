import 'dart:convert';
import 'dart:io';

/// `mcp_bridge.json`: where the tool endpoint listens and the credentials the
/// stdio bridge presents. Owner-only on disk, since both tokens are in it.
class McpBridgeHandshake {
  const McpBridgeHandshake({
    required this.port,
    required this.pid,
    this.token,
    this.socketPath,
    this.mcpToken,
    this.wslHost,
  });

  /// The file's name, in the data directory the app and the bridge share.
  static const String fileName = 'mcp_bridge.json';

  final int port;
  final int pid;

  /// The `/rpc` credential, over [socketPath] or loopback HTTP.
  final String? token;
  final String? socketPath;

  /// The unattributed `/mcp` credential.
  final String? mcpToken;

  /// The WSL switch address the endpoint also listens on, when it does.
  final String? wslHost;

  String get mcpUrl => 'http://127.0.0.1:$port/mcp';

  String encode() => jsonEncode({
    'port': port,
    'pid': pid,
    'token': ?token,
    'socketPath': ?socketPath,
    'mcpToken': ?mcpToken,
    if (mcpToken != null) 'mcpUrl': mcpUrl,
    'wslHost': ?wslHost,
  });

  /// Null for text that is not a handshake.
  static McpBridgeHandshake? parse(String text) {
    try {
      final json = jsonDecode(text);
      if (json is! Map<String, Object?>) return null;
      final port = json['port'];
      if (port is! int) return null;
      final pid = json['pid'];
      return McpBridgeHandshake(
        port: port,
        pid: pid is int ? pid : 0,
        token: json['token'] as String?,
        socketPath: json['socketPath'] as String?,
        mcpToken: json['mcpToken'] as String?,
        wslHost: json['wslHost'] as String?,
      );
    } on Object {
      return null;
    }
  }

  /// Null when the file is missing or unreadable.
  static McpBridgeHandshake? read(String path) {
    try {
      return parse(File(path).readAsStringSync());
    } on FileSystemException {
      return null;
    }
  }
}
