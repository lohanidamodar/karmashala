import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_mcp/access.dart';
import 'package:karmashala_mcp/protocol.dart';
import 'package:path/path.dart' as p;

import '../mcp/daemon_mcp.dart';
import '../pty/libc.dart';

/// How a session the host launches reaches Karmashala's tools: the URL whose
/// last segment is its own token, a config file naming that URL or the
/// bridge, or the stdio [bridge] itself.
typedef SessionMcpAccess = ({
  String? url,
  String? configPath,
  McpBridgeCommand? bridge,
});

/// The stdio bridge as an agent in WSL spawns it: [command] in the agent's
/// spelling, and the variables it needs carried across interop.
typedef McpBridgeCommand = ({String command, Map<String, String> environment});

/// What the bridge reads for its caller, and for the handshake to dial.
const String kBridgeSessionVariable = 'KARMASHALA_SESSION_ID';
const String kBridgeHandshakeVariable = 'KARMASHALA_BRIDGE_HANDSHAKE';

/// Overrides where the stdio bridge is looked for.
const String kMcpBridgeVariable = 'KARMASHALA_MCP_BRIDGE';

/// `karmashala_mcp.exe` beside this server: its own folder, else the app's
/// Release folder that a bundle's `host\bin` sits two levels under. Only
/// Windows has WSL sessions to hand it to.
File? findMcpBridge({String? executable, Map<String, String>? environment}) {
  if (!Platform.isWindows) return null;
  final named = (environment ?? Platform.environment)[kMcpBridgeVariable];
  if (named != null && named.trim().isNotEmpty) {
    final file = File(named.trim());
    return file.existsSync() ? file : null;
  }
  final bin = p.dirname(executable ?? Platform.resolvedExecutable);
  for (final folder in [
    bin,
    if (p.basename(bin) == 'bin') ...[
      p.dirname(bin),
      p.dirname(p.dirname(bin)),
    ],
  ]) {
    final file = File(p.join(folder, 'karmashala_mcp.exe'));
    if (file.existsSync()) return file;
  }
  return null;
}

/// Issues a launched session its way to this host's MCP endpoint. A session
/// on this machine dials `127.0.0.1` with a token from the caller key, so it
/// names the session exactly as an app-issued one would. One in a WSL
/// distribution is given the stdio bridge over interop when it is here: the
/// switch address resets the first data segment on some machines
/// (PROJECT.md §18), so the switch URL is only the fallback.
class SessionMcpAccessPoint {
  SessionMcpAccessPoint({
    required this.mcp,
    required this.configDirectory,
    File? Function()? bridgeExecutable,
  }) : _bridgeExecutable = bridgeExecutable ?? findMcpBridge;

  /// Null when the daemon serves no MCP; launches then carry no tool flags.
  final DaemonMcp? mcp;

  /// Where per-session config files go: `<data dir>/mcp`, as the app's.
  final String configDirectory;

  final File? Function() _bridgeExecutable;

  /// Null when nothing truthful can be handed over — no endpoint, one [kind]
  /// cannot dial (an SSH box; WSL with neither the bridge nor the switch), or
  /// a file that could not be written. A launch without tools is still a
  /// launch.
  SessionMcpAccess? accessFor(
    String sessionId, {
    required bool withConfigFile,
    EnvironmentKind kind = EnvironmentKind.localPosix,
  }) {
    final daemon = mcp;
    if (daemon == null || !daemon.serving) return null;
    final bridge = kind == EnvironmentKind.wsl
        ? _bridgeFor(sessionId, daemon)
        : null;
    final host = switch (kind) {
      EnvironmentKind.localPosix ||
      EnvironmentKind.windowsNative => '127.0.0.1',
      EnvironmentKind.wsl => daemon.endpoint.wslHost?.address,
      EnvironmentKind.ssh => null,
    };
    if (host == null && bridge == null) return null;
    final url = host == null
        ? null
        : 'http://$host:${daemon.endpoint.port}${McpHttpEndpoint.path}/'
              '${daemon.credentials.callerKey.tokenFor(sessionId)}';
    if (!withConfigFile) return (url: url, configPath: null, bridge: bridge);
    final path = _writeConfig(
      sessionId,
      bridge == null
          ? LauncherMcp.httpServerEntry(url!)
          : LauncherMcp.commandServerEntry(
              bridge.command,
              environment: bridge.environment,
            ),
    );
    if (path == null) return null;
    final named = agentConfigPathFor(path, kind);
    return named == null ? null : (url: url, configPath: named, bridge: bridge);
  }

  /// The bridge for a WSL session, or null when none is beside the server.
  /// Its session and the handshake to read are carried in `WSLENV`: without
  /// the handshake a probe's bridge would dial the real app's.
  McpBridgeCommand? _bridgeFor(String sessionId, DaemonMcp daemon) {
    final File? file;
    try {
      file = _bridgeExecutable();
    } on Object {
      return null;
    }
    if (file == null) return null;
    final command = agentConfigPathFor(file.path, EnvironmentKind.wsl);
    if (command == null) return null;
    return (
      command: command,
      environment: {
        kBridgeSessionVariable: sessionId,
        kBridgeHandshakeVariable: daemon.handshakePath,
        'WSLENV': '$kBridgeSessionVariable/u:$kBridgeHandshakeVariable/u',
      },
    );
  }

  String? _writeConfig(String sessionId, Map<String, Object?> entry) {
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
          'mcpServers': {'karmashala': entry},
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
