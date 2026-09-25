import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_host/lifecycle_client.dart' show McpCredentials;
import 'package:karmashala_mcp/access.dart';
import 'package:karmashala_mcp/protocol.dart';

import 'session_mcp.dart';

/// A launch's way to the session host's MCP endpoint: the port from the host's
/// handshake, and a token derived from the host's caller key. Both files are
/// read on every launch, so a host restarted since is what the agent is given.
class HostSessionMcp implements SessionMcp {
  HostSessionMcp({
    required this.handshakePath,
    required this.credentialsPath,
    required this.configs,
    File? Function()? bridgeExecutable,
  }) : _bridgeExecutable =
           bridgeExecutable ?? const LauncherMcp().bridgeExecutable;

  /// `<data dir>/mcp_bridge.json`, written by the host.
  final String handshakePath;

  /// `<host dir>/mcp.credentials`, whose caller key issues session tokens.
  final String credentialsPath;

  /// Where per-session configs are written, or null when none can be.
  final SessionMcpConfigs? configs;
  final File? Function() _bridgeExecutable;

  /// Whether the host's handshake carries a credential — it is serving agents.
  bool get serving => McpBridgeHandshake.read(handshakePath)?.mcpToken != null;

  /// The URL that says the caller **is** [sessionId], or null: no host has
  /// published an endpoint, it withheld its credentials, or [environment] has
  /// no address for it.
  String? mcpUrlFor(String sessionId, {required EnvironmentKind environment}) {
    final handshake = McpBridgeHandshake.read(handshakePath);
    if (handshake == null || handshake.mcpToken == null) return null;
    final credentials = McpCredentials.read(credentialsPath);
    if (credentials == null) return null;
    final host = switch (environment) {
      EnvironmentKind.windowsNative ||
      EnvironmentKind.localPosix => '127.0.0.1:${handshake.port}',
      EnvironmentKind.wsl =>
        handshake.wslHost == null
            ? null
            : '${handshake.wslHost}:${handshake.port}',
      EnvironmentKind.ssh => null,
    };
    if (host == null) return null;
    final token = credentials.callerKey.tokenFor(sessionId);
    return 'http://$host${McpHttpEndpoint.path}/$token';
  }

  @override
  SessionMcpAccess? accessFor({
    required String sessionId,
    required ExecutionEnvironment environment,
    required bool withConfigFile,
  }) => sessionMcpAccess(
    sessionId: sessionId,
    environment: environment,
    withConfigFile: withConfigFile,
    url: mcpUrlFor(sessionId, environment: environment.kind),
    configs: configs,
    bridgeExecutable: _bridgeExecutable,
  );
}
