import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../domain/browser_failure.dart';
import '../domain/browser_target.dart';
import 'cdp_payloads.dart';

/// What is (or is not) answering on the debugging port.
enum DevToolsEndpointState {
  /// A Chrome DevTools endpoint is listening and usable.
  available,

  /// Nothing is listening: the connection was refused.
  notListening,

  /// Something answered, but it is not DevTools. Spawning a browser on this
  /// port will fail, so we say so rather than trying.
  occupiedByOther,
}

/// Chrome's plain-HTTP discovery endpoint (`/json/*`) on the debugging port: it
/// lists targets, opens them, and says whether a browser is already listening
/// before we consider spawning one.
class DevToolsHttpEndpoint {
  DevToolsHttpEndpoint({
    required this.port,
    this.host = '127.0.0.1',
    HttpClient? client,
    this.timeout = const Duration(seconds: 5),
  }) : _client = client ?? HttpClient();

  final String host;
  final int port;
  final Duration timeout;
  final HttpClient _client;

  Uri _uri(String path) => Uri.parse('http://$host:$port$path');

  /// Whether a DevTools endpoint is listening, and if not, why.
  Future<DevToolsEndpointState> probe() async {
    final String body;
    try {
      body = await _request('GET', '/json/version');
    } on BrowserException catch (e) {
      if (e.failure == BrowserFailure.notRunning) {
        return DevToolsEndpointState.notListening;
      }
      // Something answered but the exchange failed: an unrelated server.
      return DevToolsEndpointState.occupiedByOther;
    }
    return isDevToolsVersionBody(body)
        ? DevToolsEndpointState.available
        : DevToolsEndpointState.occupiedByOther;
  }

  /// All debuggable targets, pages and otherwise.
  Future<List<BrowserTarget>> listTargets() async =>
      parseTargetList(await _request('GET', '/json/list'));

  /// Opens a new tab at [url] and returns its target. `PUT` rather than `GET`:
  /// Chrome 111 and later reject the old GET form.
  Future<BrowserTarget> openTab(String url) async {
    final body = await _request('PUT', '/json/new?${Uri.encodeComponent(url)}');
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, Object?>) {
      throw BrowserException(
        BrowserFailure.malformedResponse,
        describeBrowserFailure(
          BrowserFailure.malformedResponse,
          detail: '/json/new did not describe a target',
        ),
      );
    }
    return parseTarget(decoded);
  }

  Future<void> closeTab(String targetId) async {
    await _request('GET', '/json/close/$targetId');
  }

  /// Releases the underlying HTTP connections.
  void close() => _client.close(force: true);

  Future<String> _request(String method, String path) async {
    try {
      final request = await _client
          .openUrl(method, _uri(path))
          .timeout(timeout);
      final response = await request.close().timeout(timeout);
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      if (response.statusCode >= 400) {
        throw BrowserException(
          BrowserFailure.protocolError,
          describeBrowserFailure(
            BrowserFailure.protocolError,
            detail: '$path returned HTTP ${response.statusCode}',
          ),
        );
      }
      return body;
    } on SocketException catch (e) {
      throw BrowserException(
        BrowserFailure.notRunning,
        describeBrowserFailure(BrowserFailure.notRunning, port: port),
        cause: e,
      );
    } on TimeoutException catch (e) {
      throw BrowserException(
        BrowserFailure.timeout,
        describeBrowserFailure(
          BrowserFailure.timeout,
          detail: 'the debugging endpoint did not answer $path',
        ),
        cause: e,
      );
    } on HttpException catch (e) {
      throw BrowserException(
        BrowserFailure.malformedResponse,
        describeBrowserFailure(
          BrowserFailure.malformedResponse,
          detail: 'HTTP error talking to $path',
        ),
        cause: e,
      );
    }
  }
}
