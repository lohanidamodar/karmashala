import 'dart:async';
import 'dart:io';

import 'package:karmashala_local_ipc/karmashala_local_ipc.dart';
import 'package:karmashala_mcp/access.dart';
import 'package:karmashala_mcp/protocol.dart';
import 'package:path/path.dart' as p;

import '../serve/host_paths.dart';
import 'mcp_callers.dart';
import 'mcp_credentials.dart';
import 'mcp_endpoint_server.dart';
import 'mcp_handshake_file.dart';
import 'mcp_rpc_handler.dart';
import 'mcp_tool_relay.dart';

/// How often to look again for the WSL switch while it is missing.
const Duration kWslRetryInterval = Duration(seconds: 30);

/// The daemon's MCP endpoint: agents' tool calls are authenticated here and
/// run by whichever app [relay] has connected. Fails closed: with no owner-only
/// socket or handshake no credential is honoured, and agents are refused.
class DaemonMcp {
  DaemonMcp._({
    required this.credentials,
    required this.endpoint,
    required this.handshakePath,
    required McpHttpEndpoint mcp,
    required McpRpcHandler rpc,
    required LocalRpcServer? socket,
    required HandshakePermissions permissions,
    required void Function(String) log,
  }) : _mcp = mcp,
       _rpc = rpc,
       _socket = socket,
       _permissions = permissions,
       _log = log;

  final McpCredentials credentials;
  final McpEndpointServer endpoint;

  /// `<data dir>/mcp_bridge.json`, where the app and the bridge both look.
  final String handshakePath;
  final McpHttpEndpoint _mcp;
  final McpRpcHandler _rpc;
  final LocalRpcServer? _socket;
  final HandshakePermissions _permissions;
  final void Function(String) _log;
  Timer? _wslRetry;
  var _closed = false;

  /// Whether agents are being served at all.
  bool get serving => _mcp.token != null;

  String? get socketPath => _socket?.path;

  static Future<DaemonMcp> start({
    required HostPaths paths,
    required String dataDirectory,
    required McpToolRelay relay,
    bool Function(String sessionId)? sessionIsOver,
    int preferredPort = kPreferredMcpPort,
    HandshakePermissions permissions = const SystemHandshakePermissions(),
    Future<InternetAddress?> Function()? wslHostAddress,
    Duration wslRetryEvery = kWslRetryInterval,
    void Function(String message)? log,
  }) async {
    final say = log ?? (_) {};
    var credentials = await McpCredentials.loadOrCreate(
      paths.mcpCredentialsPath,
    );
    final mcp = McpHttpEndpoint(
      server: McpServer(
        name: kKarmashalaMcpName,
        version: kKarmashalaMcpVersion,
        catalogue: relay.catalogue,
        invoke: relay.call,
        instructions: kKarmashalaMcpInstructions,
      ),
      callers: DaemonMcpCallers(
        credentials.callerKey,
        sessionIsOver: sessionIsOver,
      ),
    );
    final rpc = McpRpcHandler(relay: relay);
    final socket = await _bindSocket(paths, rpc, say);
    final endpoint = await McpEndpointServer.bind(
      mcp: mcp,
      rpc: rpc,
      port: credentials.port ?? preferredPort,
    );
    if (credentials.port != endpoint.port) {
      credentials = credentials.withPort(endpoint.port);
      await credentials.write(paths.mcpCredentialsPath);
    }
    final daemon = DaemonMcp._(
      credentials: credentials,
      endpoint: endpoint,
      handshakePath: p.join(dataDirectory, McpBridgeHandshake.fileName),
      mcp: mcp,
      rpc: rpc,
      socket: socket,
      permissions: permissions,
      log: say,
    );
    // Credentials only where the owner-only socket came up: serving `/mcp`
    // without it is the silent downgrade the app refused too.
    if (socket != null) daemon._grant();
    await daemon._publish();
    if (wslHostAddress != null || Platform.isWindows) {
      daemon._wslRetryEvery = wslRetryEvery;
      await daemon._bindWsl(wslHostAddress ?? resolveWslHostAddress);
    }
    return daemon;
  }

  Duration _wslRetryEvery = kWslRetryInterval;

  void _grant() {
    _mcp.token = credentials.mcpToken;
    _rpc.token = credentials.rpcToken;
  }

  void _withhold() {
    _mcp.token = null;
    _rpc.token = null;
  }

  /// Writes the handshake; credentials go in only when it is owner-only.
  Future<void> _publish() async {
    final published = await writeMcpHandshake(
      handshakePath,
      McpBridgeHandshake(
        port: endpoint.port,
        pid: pid,
        token: _rpc.token,
        socketPath: _rpc.token == null ? null : _socket?.path,
        mcpToken: _mcp.token,
        wslHost: endpoint.wslHost?.address,
      ),
      _permissions,
    );
    if (!published && serving) {
      _log('the MCP handshake could not be made owner-only; agents refused');
      _withhold();
      await writeMcpHandshake(
        handshakePath,
        McpBridgeHandshake(port: endpoint.port, pid: pid),
        _permissions,
        restrict: false,
      );
    }
  }

  Future<void> _bindWsl(Future<InternetAddress?> Function() lookup) async {
    if (_closed) return;
    try {
      final host = await lookup();
      if (host != null) {
        await endpoint.bindWsl(host);
        _log('MCP also on ${host.address}:${endpoint.port}, for WSL sessions');
        await _publish();
        return;
      }
    } on Object catch (error) {
      _log('MCP could not listen on the WSL switch ($error)');
    }
    _wslRetry?.cancel();
    _wslRetry = Timer(_wslRetryEvery, () => unawaited(_bindWsl(lookup)));
  }

  static Future<LocalRpcServer?> _bindSocket(
    HostPaths paths,
    McpRpcHandler rpc,
    void Function(String) say,
  ) async {
    try {
      final String path;
      switch (locateSocket(paths.preferredMcpSocketPath)) {
        case PreferredSocketLocation(path: final preferred):
          path = preferred;
        case final FallbackSocketLocation location:
          final refused =
              await prepareFallbackSocketDirectory(location) ??
              await HostPaths(
                Directory(location.directory),
              ).restrictToCurrentUser();
          if (refused != null) {
            say('no MCP socket: $refused');
            return null;
          }
          path = location.path;
        case UnplaceableSocket(:final reason):
          say('no MCP socket: $reason');
          return null;
      }
      return await LocalRpcServer.bind(path, rpc.handleSocketLine);
    } on Object catch (error) {
      say('no MCP socket ($error)');
      return null;
    }
  }

  /// Takes the handshake off disk first, so no bridge dials a closing port.
  Future<void> close() async {
    _closed = true;
    _wslRetry?.cancel();
    try {
      final file = File(handshakePath);
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // Held open by a bridge reading it; the next start replaces it.
    }
    await endpoint.close();
    await _socket?.close();
  }
}
