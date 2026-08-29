import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/logging/app_logger.dart';
import 'agent_hook_receiver.dart';

/// Where an agent's installed hooks call back to, and the token they must send.
class AgentHookEndpoint {
  const AgentHookEndpoint({required this.port, required this.token});

  final int port;
  final String token;

  Uri uriFor({required String agentId, required String event}) => Uri.parse(
    'http://127.0.0.1:$port/agent-hook?agent=$agentId&event=$event',
  );
}

/// A loopback HTTP host for agent hook callbacks.
///
/// It follows the same shape as the launcher control server — 127.0.0.1, an
/// ephemeral port, a `Random.secure` bearer token, and a handshake JSON file in
/// the application-support directory — because nothing on the network should be
/// able to reach it.
///
/// This is a **temporary host**. The intended end state is a `/agent-hook`
/// route on `LauncherControlServer` with [AgentHookReceiver] moved across
/// unchanged; that file belongs to another branch today, so the endpoint lives
/// here for now.
class AgentHookServer {
  AgentHookServer(this._receiver, {AppLogger? logger})
    : _logger = logger ?? AppLogger.named('agent-hooks');

  final AgentHookReceiver _receiver;
  final AppLogger _logger;

  HttpServer? _server;
  AgentHookEndpoint? _endpoint;

  AgentHookEndpoint? get endpoint => _endpoint;

  /// Binds the endpoint and writes the handshake file. Pass
  /// [handshakeFilePath] to control where that file goes (tests do); by default
  /// it is `agent_hooks.json` in the application-support directory.
  Future<AgentHookEndpoint> start({String? handshakeFilePath}) async {
    final existing = _endpoint;
    if (existing != null) return existing;

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final endpoint = AgentHookEndpoint(
      port: server.port,
      token: _generateToken(),
    );
    _server = server;
    _endpoint = endpoint;
    await _writeHandshake(endpoint, handshakeFilePath);
    server.listen(
      (request) => _handle(request, endpoint),
      onError: (Object e) => _logger.warning('$e'),
    );
    _logger.info('Agent hook endpoint on 127.0.0.1:${server.port}.');
    return endpoint;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _endpoint = null;
  }

  Future<void> _writeHandshake(
    AgentHookEndpoint endpoint,
    String? overridePath,
  ) async {
    String path;
    if (overridePath != null) {
      path = overridePath;
    } else {
      try {
        final dir = await getApplicationSupportDirectory();
        path = p.join(dir.path, 'agent_hooks.json');
      } catch (_) {
        return; // No support directory (unit tests) — the port is enough.
      }
    }
    await File(path).writeAsString(
      jsonEncode({'port': endpoint.port, 'token': endpoint.token, 'pid': pid}),
      flush: true,
    );
  }

  String _generateToken() {
    final random = Random.secure();
    return base64Url.encode(List<int>.generate(24, (_) => random.nextInt(256)));
  }

  Future<void> _handle(HttpRequest request, AgentHookEndpoint endpoint) async {
    final response = request.response;
    try {
      if (request.headers.value(HttpHeaders.authorizationHeader) !=
          'Bearer ${endpoint.token}') {
        response.statusCode = HttpStatus.unauthorized;
        await response.close();
        return;
      }
      if (request.method != 'POST' || request.uri.path != '/agent-hook') {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      final body = await utf8.decoder.bind(request).join();
      final report = _receiver.handle(
        agentId: request.uri.queryParameters['agent'],
        event: request.uri.queryParameters['event'],
        body: body,
      );
      // Always 200 on an authenticated callback, even for an event we do not
      // recognise: a hook must never block the agent that fired it.
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode({'ok': true, 'status': report.status.name}));
      await response.close();
    } catch (error) {
      _logger.warning('Agent hook callback failed: $error');
      response.statusCode = HttpStatus.internalServerError;
      await response.close();
    }
  }
}
