import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart' show AgentLatestVersionSource;

/// Why a latest-version check did not produce a version, in words short
/// enough to follow "couldn't check: ".
class AgentLatestVersionException implements Exception {
  const AgentLatestVersionException(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// **Reads an agent's newest published version from its declared source.**
///
/// One GET to a public, unauthenticated document — the npm registry's
/// `latest` dist-tag — carrying no cookie, token or anything about the user
/// or their machines. `dart:io`'s [HttpClient], as the usage endpoints use,
/// rather than a new package for one request.
class AgentLatestVersionFetcher {
  AgentLatestVersionFetcher({
    HttpClient Function()? newClient,
    this.timeout = const Duration(seconds: 10),
  }) : _newClient = newClient ?? HttpClient.new;

  final HttpClient Function() _newClient;

  /// For the whole request: a registry that does not answer is a failed
  /// check, not a spinner on the settings page.
  final Duration timeout;

  /// The version [source] names as latest. Throws
  /// [AgentLatestVersionException] with a readable reason on any failure.
  Future<String> fetch(AgentLatestVersionSource source) async {
    final url = source.url;
    if (url == null) {
      throw const AgentLatestVersionException('no public source is known');
    }
    final client = _newClient()..connectionTimeout = timeout;
    try {
      return await _get(client, url).timeout(timeout);
    } on AgentLatestVersionException {
      rethrow;
    } on TimeoutException {
      throw const AgentLatestVersionException('the registry did not answer');
    } on SocketException catch (e) {
      throw AgentLatestVersionException('no connection (${e.message})');
    } on HandshakeException {
      throw const AgentLatestVersionException('secure connection failed');
    } on FormatException {
      throw const AgentLatestVersionException(
        'the registry sent something unreadable',
      );
    } catch (e) {
      throw AgentLatestVersionException('$e');
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _get(HttpClient client, Uri url) async {
    final request = await client.getUrl(url);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != HttpStatus.ok) {
      throw AgentLatestVersionException(
        'the registry answered HTTP ${response.statusCode}',
      );
    }
    final decoded = jsonDecode(body);
    final version = decoded is Map<String, dynamic> ? decoded['version'] : null;
    if (version is! String || version.trim().isEmpty) {
      throw const AgentLatestVersionException('the registry named no version');
    }
    return version.trim();
  }
}
