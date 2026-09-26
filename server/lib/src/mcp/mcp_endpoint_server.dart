import 'dart:async';
import 'dart:io';

import 'package:karmashala_mcp/protocol.dart';

import 'mcp_rpc_handler.dart';

/// The port asked for when no earlier one is remembered — the app's, because a
/// Hyper-V firewall rule names a port, never a program.
const int kPreferredMcpPort = 47821;

/// The loopback HTTP listener agents dial: `/mcp[/<token>]` for MCP itself and
/// `/rpc` for the bridge, answered exactly as the app's server answered them.
class McpEndpointServer {
  McpEndpointServer._(this._server, this._mcp, this._rpc) {
    _server.listen((request) => unawaited(_handle(request)));
  }

  /// Binds [port], falling back to any free port when it is taken.
  static Future<McpEndpointServer> bind({
    required McpHttpEndpoint mcp,
    required McpRpcHandler rpc,
    int port = kPreferredMcpPort,
  }) async {
    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    } on SocketException {
      if (port == 0) rethrow;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    }
    return McpEndpointServer._(server, mcp, rpc);
  }

  final HttpServer _server;
  final McpHttpEndpoint _mcp;
  final McpRpcHandler _rpc;
  HttpServer? _wsl;

  int get port => _server.port;

  /// The WSL switch address also served, or null.
  InternetAddress? get wslHost => _wsl?.address;

  /// Also listens on [host] — the WSL switch — for `/mcp` alone.
  Future<void> bindWsl(InternetAddress host) async {
    if (_wsl != null) return;
    final server = await HttpServer.bind(host, port);
    _wsl = server;
    server.listen((request) => unawaited(_handleWsl(request)));
  }

  Future<void> close() async {
    await _server.close(force: true);
    await _wsl?.close(force: true);
  }

  Future<void> _handleWsl(HttpRequest request) async {
    if (McpHttpEndpoint.handles(request.uri)) return _mcp.handle(request);
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  Future<void> _handle(HttpRequest request) async {
    // MCP authenticates itself, with its own credentials and its own rule for
    // who the caller is, so it is routed before the bearer check.
    if (McpHttpEndpoint.handles(request.uri)) return _mcp.handle(request);
    final response = request.response;
    try {
      final header = request.headers.value(HttpHeaders.authorizationHeader);
      final bearer = header != null && header.startsWith('Bearer ')
          ? header.substring('Bearer '.length)
          : null;
      if (!_rpc.authorises(bearer)) {
        response.statusCode = HttpStatus.unauthorized;
        return;
      }
      // `/rpc` goes over the owner-only socket; loopback HTTP never serves it.
      response.statusCode = HttpStatus.notFound;
    } finally {
      try {
        await response.close();
      } on Object {
        // The caller hung up first.
      }
    }
  }
}
