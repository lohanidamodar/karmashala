import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_mcp/access.dart';
import 'package:karmashala_mcp/protocol.dart';
import 'package:path/path.dart' as p;

import '../mcp/daemon_mcp.dart';
import '../pty/libc.dart';

/// How a session the host launches reaches Karmashala's tools: the URL whose
/// last segment is its own token, or a config file naming that URL.
typedef SessionMcpAccess = ({String? url, String? configPath});

/// Issues a launched session its way to this host's MCP endpoint. A session
/// on this machine dials `127.0.0.1`, one in a WSL distribution the address
/// the endpoint also listens on for WSL (slice 5b); the token is the caller
/// key's, so it names the session exactly as an app-issued one would.
class SessionMcpAccessPoint {
  SessionMcpAccessPoint({required this.mcp, required this.configDirectory});

  /// Null when the daemon serves no MCP; launches then carry no tool flags.
  final DaemonMcp? mcp;

  /// Where per-session config files go: `<data dir>/mcp`, as the app's.
  final String configDirectory;

  /// Null when nothing truthful can be handed over — no endpoint, one [kind]
  /// cannot dial (an SSH box; WSL before the endpoint listens on its switch),
  /// or a file that could not be written. A launch without tools is still a
  /// launch.
  SessionMcpAccess? accessFor(
    String sessionId, {
    required bool withConfigFile,
    EnvironmentKind kind = EnvironmentKind.localPosix,
  }) {
    final daemon = mcp;
    if (daemon == null || !daemon.serving) return null;
    final host = switch (kind) {
      EnvironmentKind.localPosix ||
      EnvironmentKind.windowsNative => '127.0.0.1',
      EnvironmentKind.wsl => daemon.endpoint.wslHost?.address,
      EnvironmentKind.ssh => null,
    };
    if (host == null) return null;
    final token = daemon.credentials.callerKey.tokenFor(sessionId);
    final url =
        'http://$host:${daemon.endpoint.port}${McpHttpEndpoint.path}/$token';
    if (!withConfigFile) return (url: url, configPath: null);
    final path = _writeConfig(sessionId, url);
    if (path == null) return null;
    final named = agentConfigPathFor(path, kind);
    return named == null ? null : (url: url, configPath: named);
  }

  String? _writeConfig(String sessionId, String url) {
    try {
      final directory = Directory(configDirectory)..createSync(recursive: true);
      final safe = sessionId.replaceAll(RegExp('[^A-Za-z0-9-]'), '_');
      final file = File(p.join(directory.path, 'session-$safe.json'));
      // Owner-only while still empty: the token inside is a credential.
      file.writeAsStringSync('', flush: true);
      // Not `Process.runSync('chmod')`: this runs on the isolate that answers
      // every client, and a synchronous wait on another process there is a
      // wait for everyone (see `Libc.chmod`).
      if (!Platform.isWindows && !Libc.open().chmod(file.path, 0x180)) {
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

/// [hostPath] — a file this server wrote on its own machine — as an agent
/// running in [kind] names it, or null when it has no name for it: a path an
/// agent cannot open is worse than no path.
String? agentConfigPathFor(String hostPath, EnvironmentKind kind) {
  switch (kind) {
    case EnvironmentKind.windowsNative:
    case EnvironmentKind.localPosix:
      return hostPath;
    case EnvironmentKind.wsl:
      try {
        return const PathTranslator().windowsDriveToWslMount(hostPath);
      } on PathTranslationException {
        return null;
      }
    case EnvironmentKind.ssh:
      return null;
  }
}
