import 'dart:convert';
import 'dart:io';

import 'package:karmashala_mcp/protocol.dart';

/// `<hostDir>/mcp.credentials`: the MCP endpoint's secrets and the port it last
/// bound. Minted once and kept, so every URL an agent holds survives a restart
/// of the daemon and of the app.
class McpCredentials {
  const McpCredentials({
    required this.callerKey,
    required this.mcpToken,
    required this.rpcToken,
    this.port,
  });

  factory McpCredentials.generate() => McpCredentials(
    callerKey: McpCallerKey.generate(),
    mcpToken: generateSecret(),
    rpcToken: generateSecret(),
  );

  /// What each session's token is derived from; the app reads it to issue one.
  final McpCallerKey callerKey;

  /// The unattributed `/mcp` credential, published in the bridge handshake.
  final String mcpToken;

  /// The bridge's `/rpc` credential.
  final String rpcToken;

  /// The port last bound, asked for first so a URL in a config stays valid.
  final int? port;

  McpCredentials withPort(int port) => McpCredentials(
    callerKey: callerKey,
    mcpToken: mcpToken,
    rpcToken: rpcToken,
    port: port,
  );

  String encode() => jsonEncode({
    'callerKey': callerKey.secret,
    'mcpToken': mcpToken,
    'rpcToken': rpcToken,
    'port': ?port,
  });

  /// Null for text that is not a whole credentials file.
  static McpCredentials? parse(String text) {
    try {
      final json = jsonDecode(text);
      if (json is! Map<String, Object?>) return null;
      final key = json['callerKey'];
      final mcp = json['mcpToken'];
      final rpc = json['rpcToken'];
      if (key is! String || mcp is! String || rpc is! String) return null;
      if (key.isEmpty || mcp.isEmpty || rpc.isEmpty) return null;
      final port = json['port'];
      return McpCredentials(
        callerKey: McpCallerKey(key),
        mcpToken: mcp,
        rpcToken: rpc,
        port: port is int ? port : null,
      );
    } on FormatException {
      return null;
    }
  }

  /// Null when missing, unreadable or damaged.
  static McpCredentials? read(String path) {
    try {
      return parse(File(path).readAsStringSync());
    } on FileSystemException {
      return null;
    }
  }

  /// What is at [path], or new credentials written there.
  static Future<McpCredentials> loadOrCreate(String path) async {
    final existing = read(path);
    if (existing != null) return existing;
    final minted = McpCredentials.generate();
    await minted.write(path);
    return minted;
  }

  /// Staged owner-only before a secret goes in, then renamed over [path]. On
  /// Windows the host directory's inherited ACL is what closes it.
  Future<void> write(String path) => writeOwnerOnly(path, encode());
}

/// Writes [text] to [path] through a `.tmp` made owner-only while still empty.
Future<void> writeOwnerOnly(String path, String text) async {
  final staged = File('$path.tmp');
  if (staged.existsSync()) staged.deleteSync();
  staged.createSync(recursive: true);
  if (!Platform.isWindows) {
    final result = await Process.run('chmod', ['600', staged.path]);
    if (result.exitCode != 0) {
      staged.deleteSync();
      throw FileSystemException(
        'chmod 600 failed: ${result.stderr}',
        staged.path,
      );
    }
  }
  staged.writeAsStringSync(text, flush: true);
  staged.renameSync(path);
}
