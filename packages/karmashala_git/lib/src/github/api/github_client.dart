import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'github_credentials.dart';
import 'github_hosts.dart';

/// One answer from GitHub. [body] is decoded JSON when GitHub sent JSON, the
/// text otherwise.
class GithubResponse {
  const GithubResponse({
    required this.status,
    required this.body,
    this.headers = const {},
    this.fromCache = false,
  });

  final int status;
  final Object? body;

  /// Lower-cased names.
  final Map<String, String> headers;

  /// A 304 answered from the copy kept with its ETag.
  final bool fromCache;

  bool get ok => status >= 200 && status < 300;

  String? get etag => headers['etag'];

  int? get remaining => int.tryParse(headers['x-ratelimit-remaining'] ?? '');

  DateTime? get resetAt {
    final reset = int.tryParse(headers['x-ratelimit-reset'] ?? '');
    return reset == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(reset * 1000, isUtc: true);
  }

  /// GitHub's own `message`, when the body carries one.
  String? get message {
    final value = body;
    if (value is Map && value['message'] is String) {
      return value['message'] as String;
    }
    return null;
  }

  String get text => switch (body) {
    null => '',
    final String text => text,
    final Object value => jsonEncode(value),
  };
}

/// GitHub answered, and not with a success.
class GithubApiException implements Exception {
  GithubApiException(this.message, {this.status});

  final String message;
  final int? status;

  @override
  String toString() => message;
}

/// The token's budget is spent until [until]; nothing was sent.
class GithubRateLimited extends GithubApiException {
  GithubRateLimited(String host, this.until)
    : super(
        'GitHub\'s rate limit for $host is spent until '
        '${until.toUtc().toIso8601String()}.',
        status: 403,
      );

  final DateTime until;
}

/// GitHub's REST and GraphQL APIs over HTTP, as whichever token
/// [GithubCredentials] gives for the host. GETs are asked again with their
/// ETag; a spent rate budget is waited out rather than spent further.
class GithubClient {
  GithubClient({
    required this.credentials,
    HttpClient Function()? httpClient,
    Uri Function(String host)? apiBaseOf,
    Uri Function(String host)? graphqlOf,
    DateTime Function()? now,
    this.timeout = const Duration(seconds: 30),
    this.keptAnswers = 256,
  }) : _httpClient = httpClient ?? HttpClient.new,
       _apiBaseOf = apiBaseOf ?? githubApiBase,
       _graphqlOf = graphqlOf ?? githubGraphqlEndpoint,
       _now = now ?? DateTime.now;

  final GithubCredentials credentials;
  final Duration timeout;

  /// How many ETag answers are kept, oldest dropped first.
  final int keptAnswers;

  final HttpClient Function() _httpClient;
  final Uri Function(String host) _apiBaseOf;
  final Uri Function(String host) _graphqlOf;
  final DateTime Function() _now;

  final Map<String, GithubResponse> _kept = {};
  final Map<String, DateTime> _spentUntil = {};

  static const int _maxRedirects = 5;

  /// A REST call on [host]: [path] is relative to its API root
  /// (`repos/o/r/pulls`), and may carry a query.
  Future<GithubResponse> rest(
    String host,
    String path, {
    String method = 'GET',
    Map<String, String>? query,
    Object? body,
    String accept = 'application/vnd.github+json',
  }) async {
    final token = await credentials.requireTokenFor(host);
    return restAs(
      token,
      path,
      method: method,
      query: query,
      body: body,
      accept: accept,
    );
  }

  /// [rest] with a token the caller already holds — Settings' Test.
  Future<GithubResponse> restAs(
    GithubToken token,
    String path, {
    String method = 'GET',
    Map<String, String>? query,
    Object? body,
    String accept = 'application/vnd.github+json',
  }) {
    var url = _apiBaseOf(
      token.host,
    ).resolve(path.startsWith('/') ? path.substring(1) : path);
    if (query != null && query.isNotEmpty) {
      url = url.replace(queryParameters: {...url.queryParameters, ...query});
    }
    return _send(token, method, url, body: body, accept: accept);
  }

  /// One GraphQL document on [host]; GraphQL `errors` beside no `data`
  /// throw, a partial `data` is returned whole.
  Future<Map<String, Object?>> graphql(
    String host,
    String query, {
    Map<String, Object?> variables = const {},
  }) async {
    final token = await credentials.requireTokenFor(host);
    final response = await _send(
      token,
      'POST',
      _graphqlOf(token.host),
      body: {'query': query, 'variables': variables},
      // `mergeStateStatus` is still behind this preview on some hosts.
      accept: 'application/vnd.github.merge-info-preview+json',
    );
    _ensureOk(response, 'GraphQL');
    final body = response.body;
    if (body is! Map) {
      throw GithubApiException('GitHub\'s GraphQL answer was not an object.');
    }
    final data = body['data'];
    if (data == null && body['errors'] is List) {
      final errors = body['errors'] as List;
      final first = errors.isEmpty ? null : errors.first;
      throw GithubApiException(
        first is Map && first['message'] is String
            ? first['message'] as String
            : 'GitHub\'s GraphQL call failed.',
      );
    }
    return body.cast<String, Object?>();
  }

  /// When [token]'s budget comes back, while it is spent.
  DateTime? spentUntil(GithubToken token) {
    final until = _spentUntil[token.key];
    return until != null && _now().isBefore(until) ? until : null;
  }

  Future<GithubResponse> _send(
    GithubToken token,
    String method,
    Uri url, {
    Object? body,
    required String accept,
  }) async {
    if (spentUntil(token) case final until?) {
      throw GithubRateLimited(token.host, until);
    }
    final cacheKey = method == 'GET' ? '${token.key} $url' : null;
    final kept = cacheKey == null ? null : _kept[cacheKey];
    final origin = _originOf(url);
    final client = _httpClient()..autoUncompress = true;
    try {
      var hop = url;
      var hopMethod = method;
      Object? hopBody = body;
      for (var redirects = 0; ; redirects++) {
        final sameOrigin = _originOf(hop) == origin;
        final request = await client.openUrl(hopMethod, hop).timeout(timeout);
        request
          ..followRedirects = false
          ..headers.set(HttpHeaders.acceptHeader, accept)
          ..headers.set(HttpHeaders.userAgentHeader, 'Karmashala')
          ..headers.set('X-GitHub-Api-Version', '2022-11-28');
        // A token never leaves the host it was issued for, redirect or not.
        if (sameOrigin) {
          request.headers.set(
            HttpHeaders.authorizationHeader,
            'Bearer ${token.value}',
          );
          if (kept?.etag case final etag? when redirects == 0) {
            request.headers.set(HttpHeaders.ifNoneMatchHeader, etag);
          }
        }
        if (hopBody != null) {
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(hopBody));
        }
        final response = await request.close().timeout(timeout);
        final status = response.statusCode;
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (const {301, 302, 303, 307, 308}.contains(status) &&
            location != null) {
          await response.drain<void>();
          if (redirects >= _maxRedirects) {
            throw GithubApiException('GitHub redirected too many times.');
          }
          hop = hop.resolve(location);
          if (status == 303 ||
              ((status == 301 || status == 302) && hopMethod == 'POST')) {
            hopMethod = 'GET';
            hopBody = null;
          }
          continue;
        }
        final headers = <String, String>{};
        response.headers.forEach((name, values) {
          headers[name.toLowerCase()] = values.join(', ');
        });
        final text = await utf8.decodeStream(response).timeout(timeout);
        final answer = GithubResponse(
          status: status,
          body: _decode(text, headers['content-type']),
          headers: headers,
        );
        final spent = sameOrigin ? _isSpent(answer) : null;
        if (spent != null) _spentUntil[token.key] = spent;
        if (status == 304 && kept != null) {
          return GithubResponse(
            status: kept.status,
            body: kept.body,
            headers: {...kept.headers, ...headers},
            fromCache: true,
          );
        }
        if (cacheKey != null && status == 200 && answer.etag != null) {
          _keep(cacheKey, answer);
        }
        if (spent != null) throw GithubRateLimited(token.host, spent);
        return answer;
      }
    } on SocketException catch (error) {
      throw GithubApiException('Could not reach ${url.host}: ${error.message}');
    } on TimeoutException {
      throw GithubApiException('${url.host} did not answer in time.');
    } on HttpException catch (error) {
      throw GithubApiException('${url.host}: ${error.message}');
    } finally {
      client.close(force: true);
    }
  }

  static String _originOf(Uri url) => '${url.scheme}://${url.host}:${url.port}';

  static Object? _decode(String text, String? contentType) {
    if (text.isEmpty) return null;
    if (contentType != null && !contentType.contains('json')) return text;
    try {
      return jsonDecode(text);
    } on FormatException {
      return text;
    }
  }

  void _keep(String key, GithubResponse answer) {
    _kept.remove(key);
    _kept[key] = answer;
    while (_kept.length > keptAnswers) {
      _kept.remove(_kept.keys.first);
    }
  }

  /// When a 403 or 429 says the budget is spent, until when.
  DateTime? _isSpent(GithubResponse answer) {
    if (answer.status != 403 && answer.status != 429) return null;
    final retryAfter = int.tryParse(answer.headers['retry-after'] ?? '');
    if (retryAfter != null) return _now().add(Duration(seconds: retryAfter));
    if (answer.remaining == 0) {
      return answer.resetAt ?? _now().add(const Duration(minutes: 15));
    }
    return null;
  }

  static void _ensureOk(GithubResponse response, String what) {
    if (response.ok) return;
    throw GithubApiException(
      '$what failed: HTTP ${response.status}'
      '${response.message == null ? '' : ' — ${response.message}'}',
      status: response.status,
    );
  }
}

/// Throws [GithubApiException] unless [response] succeeded.
void ensureGithubOk(GithubResponse response, String what) =>
    GithubClient._ensureOk(response, what);
