import 'dart:convert';
import 'dart:io';

import 'package:karmashala_mcp/access.dart';
import 'package:karmashala_mcp/protocol.dart';
import 'package:path/path.dart' as p;

import '../mcp/daemon_mcp.dart';

/// How a session the host launches reaches Karmashala's tools: the URL whose
/// last segment is its own token, or a config file naming that URL.
typedef SessionMcpAccess = ({String? url, String? configPath});

/// Issues a launched session its way to this host's MCP endpoint. A session
/// on this machine dials `127.0.0.1`; the token is the caller key's, so it
/// names the session exactly as an app-issued one would.
class SessionMcpAccessPoint {
  SessionMcpAccessPoint({required this.mcp, required this.configDirectory});

  /// Null when the daemon serves no MCP; launches then carry no tool flags.
  final DaemonMcp? mcp;

  /// Where per-session config files go: `<data dir>/mcp`, as the app's.
  final String configDirectory;

  /// Null when nothing truthful can be handed over — no endpoint, or a file
  /// that could not be written. A launch without tools is still a launch.
  SessionMcpAccess? accessFor(
    String sessionId, {
    required bool withConfigFile,
  }) {
    final daemon = mcp;
    if (daemon == null || !daemon.serving) return null;
    final token = daemon.credentials.callerKey.tokenFor(sessionId);
    final url =
        'http://127.0.0.1:${daemon.endpoint.port}${McpHttpEndpoint.path}/$token';
    if (!withConfigFile) return (url: url, configPath: null);
    final path = _writeConfig(sessionId, url);
    return path == null ? null : (url: url, configPath: path);
  }

  String? _writeConfig(String sessionId, String url) {
    try {
      final directory = Directory(configDirectory)..createSync(recursive: true);
      final safe = sessionId.replaceAll(RegExp('[^A-Za-z0-9-]'), '_');
      final file = File(p.join(directory.path, 'session-$safe.json'));
      // Owner-only while still empty: the token inside is a credential.
      file.writeAsStringSync('', flush: true);
      if (!Platform.isWindows &&
          Process.runSync('chmod', ['600', file.path]).exitCode != 0) {
        file.deleteSync();
        return null;
      }
      file.writeAsStringSync(
        jsonEncode({
          'mcpServers': {'karmashala': LauncherMcp.httpServerEntry(url)},
        }),
        flush: true,
      );
      return file.path;
    } on Object {
      return null;
    }
  }
}
