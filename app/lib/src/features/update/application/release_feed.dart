import 'dart:convert';

import '../domain/github_release.dart';
import 'update_ports.dart';

/// Why the release check produced nothing, in words that follow
/// "Could not check: ".
class ReleaseFeedException implements Exception {
  const ReleaseFeedException(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// Reads GitHub's latest release, unauthenticated, with `If-None-Match` from
/// the last answer: a 304 costs nothing against the 60-an-hour limit and
/// returns the release read before.
class ReleaseFeed {
  ReleaseFeed(this._http, {Uri? url, this.userAgent = 'Karmashala'})
    : _url = url ?? kLatestReleaseUrl;

  final UpdateHttp _http;
  final Uri _url;
  final String userAgent;

  String? _etag;
  GitHubRelease? _last;

  /// The latest release, or null when the repository has none. Throws
  /// [ReleaseFeedException].
  Future<GitHubRelease?> latest() async {
    final UpdateHttpResponse response;
    try {
      response = await _http.get(
        _url,
        headers: {
          'accept': 'application/vnd.github+json',
          'user-agent': userAgent,
          'x-github-api-version': '2022-11-28',
          'if-none-match': ?_etag,
        },
      );
    } on ReleaseFeedException {
      rethrow;
    } on Object catch (error) {
      throw ReleaseFeedException('no connection ($error)');
    }
    switch (response.statusCode) {
      case 304:
        return _last;
      case 404:
        // No published release yet: nothing to offer, not a failure.
        _etag = null;
        _last = null;
        return null;
      case 403 || 429:
        throw const ReleaseFeedException(
          "GitHub's hourly limit for this network is used up",
        );
      case 200:
        break;
      default:
        throw ReleaseFeedException(
          'GitHub answered HTTP ${response.statusCode}',
        );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const ReleaseFeedException('GitHub sent something unreadable');
    }
    final release = GitHubRelease.fromJson(decoded);
    if (release == null) {
      throw const ReleaseFeedException(
        "the latest release's tag is not a version",
      );
    }
    _etag = response.headers['etag'];
    _last = release;
    return release;
  }
}
