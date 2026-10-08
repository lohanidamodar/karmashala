/// Test doubles for GitHub: a loopback HTTP server that stands in for GitHub's
/// API, and saved tokens held in a map. Never reaches the real GitHub.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'src/github/api/github_client.dart';
import 'src/github/api/github_credentials.dart';

/// Settings tokens held in a map, by host.
class GithubTokenMap implements GithubSavedTokens {
  GithubTokenMap([Map<String, String>? tokens]) : tokens = {...?tokens};

  final Map<String, String> tokens;

  @override
  String? tokenFor(String host) => tokens[host];
}

/// One request the fake server received.
class FakeGithubRequest {
  FakeGithubRequest({
    required this.method,
    required this.uri,
    required this.headers,
    required this.body,
  });

  final String method;
  final Uri uri;

  /// Lower-cased names.
  final Map<String, String> headers;
  final String body;

  String get path => uri.path;
  String? get authorization => headers['authorization'];

  Object? get json => body.isEmpty ? null : jsonDecode(body);
}

/// What the fake server answers. A non-string [body] is sent as JSON.
class FakeGithubReply {
  const FakeGithubReply(this.status, {this.body, this.headers = const {}});

  final int status;
  final Object? body;
  final Map<String, String> headers;
}

typedef FakeGithubHandler = FakeGithubReply Function(FakeGithubRequest request);

/// A loopback stand-in for GitHub's API. Routes are `METHOD /path` without
/// the query; anything unrouted answers 404.
class FakeGithubServer {
  FakeGithubServer._(this._server) {
    _server.listen(_serve);
  }

  static Future<FakeGithubServer> start() async => FakeGithubServer._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
  );

  final HttpServer _server;
  final Map<String, FakeGithubHandler> _routes = {};
  final List<FakeGithubRequest> requests = [];

  /// The API root, as a REST base.
  Uri get base => Uri.parse('http://127.0.0.1:${_server.port}/');

  Uri get graphql => base.resolve('graphql');

  void on(String method, String path, FakeGithubHandler handler) =>
      _routes['$method $path'] = handler;

  /// GraphQL answers by a word the query contains.
  void onGraphql(Map<String, FakeGithubHandler> byWord) =>
      on('POST', '/graphql', (request) {
        final query = '${(request.json as Map?)?['query']}';
        for (final MapEntry(:key, :value) in byWord.entries) {
          if (query.contains(key)) return value(request);
        }
        return const FakeGithubReply(200, body: {'data': null});
      });

  Future<void> _serve(HttpRequest request) async {
    final body = await utf8.decodeStream(request);
    final headers = <String, String>{};
    request.headers.forEach((name, values) {
      headers[name.toLowerCase()] = values.join(', ');
    });
    final seen = FakeGithubRequest(
      method: request.method,
      uri: request.uri,
      headers: headers,
      body: body,
    );
    requests.add(seen);
    final handler = _routes['${request.method} ${request.uri.path}'];
    final reply =
        handler?.call(seen) ??
        const FakeGithubReply(404, body: {'message': 'Not Found'});
    final response = request.response..statusCode = reply.status;
    reply.headers.forEach(response.headers.set);
    final out = reply.body;
    if (out is String) {
      response.headers.contentType ??= ContentType.text;
      response.write(out);
    } else if (out != null) {
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(out));
    }
    await response.close();
  }

  Future<void> close() => _server.close(force: true);
}

/// A client whose every host is [server].
GithubClient fakeGithubClient(
  FakeGithubServer server,
  GithubCredentials credentials, {
  DateTime Function()? now,
}) => GithubClient(
  credentials: credentials,
  apiBaseOf: (_) => server.base,
  graphqlOf: (_) => server.graphql,
  now: now,
);
