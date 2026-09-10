/// A repository on a remote host, derived from an `origin` URL.
///
/// The web URLs are GitHub-shaped (`/commit/<sha>`, `/pull/<n>`); a second forge
/// would add a flavour here rather than a second parser.
class RemoteRepo {
  const RemoteRepo({required this.host, required this.slug});

  /// The host as the browser would address it, lower-cased. An ssh port is not
  /// part of it — `ssh://git@host:2222/o/r` is served over https on the web —
  /// but an explicit http(s) port is kept, because that one *is* the web port.
  final String host;

  /// Everything after the host: `owner/repo`, or a deeper path on forges that
  /// nest groups.
  final String slug;

  String get owner => slug.split('/').first;
  String get name => slug.split('/').last;

  String get webUrl => 'https://$host/$slug';
  String commitUrl(String sha) => '$webUrl/commit/$sha';
  String pullRequestUrl(int number) => '$webUrl/pull/$number';
  String branchUrl(String branch) => '$webUrl/tree/$branch';

  /// `owner/repo`, which is how GitHub itself names a repository.
  String get nameWithOwner => slug;

  /// Reads an `origin` URL in any of the forms git accepts, or returns null
  /// when it names something that has no web page — a local path, a `file://`
  /// URL, or a string that is not a remote at all.
  static RemoteRepo? parse(String? url) {
    if (url == null) return null;
    final value = url.trim();
    if (value.isEmpty) return null;

    final scheme = RegExp(r'^([A-Za-z][A-Za-z0-9+.\-]*)://').firstMatch(value);
    final String host;
    final String path;

    if (scheme != null) {
      final protocol = scheme.group(1)!.toLowerCase();
      if (protocol == 'file') return null;
      final rest = value.substring(scheme.end);
      final slash = rest.indexOf('/');
      if (slash <= 0) return null;
      final authority = _stripCredentials(rest.substring(0, slash));
      if (authority.isEmpty) return null;
      host = _stripSshPort(authority, keepPort: _isWeb(protocol));
      path = rest.substring(slash + 1);
    } else {
      // scp-like: `[user@]host:path`. A Windows path (`C:\src\app`) has the
      // same colon, so the host must look like a hostname before this is read
      // as a remote at all.
      final at = value.lastIndexOf('@');
      final rest = at >= 0 ? value.substring(at + 1) : value;
      final colon = rest.indexOf(':');
      if (colon <= 0) return null;
      final candidate = rest.substring(0, colon);
      if (at < 0 && !candidate.contains('.')) return null;
      host = candidate.toLowerCase();
      path = rest.substring(colon + 1);
    }

    final slug = _normalizePath(path);
    if (slug == null || !slug.contains('/')) return null;
    return RemoteRepo(host: host, slug: slug);
  }

  static bool _isWeb(String protocol) =>
      protocol == 'http' || protocol == 'https';

  static String _stripCredentials(String authority) {
    final at = authority.lastIndexOf('@');
    return at < 0 ? authority : authority.substring(at + 1);
  }

  static String _stripSshPort(String authority, {required bool keepPort}) {
    final colon = authority.lastIndexOf(':');
    if (colon < 0) return authority.toLowerCase();
    final port = authority.substring(colon + 1);
    if (int.tryParse(port) == null) return authority.toLowerCase();
    return (keepPort ? authority : authority.substring(0, colon)).toLowerCase();
  }

  static String? _normalizePath(String path) {
    var value = path.replaceAll('\\', '/');
    while (value.startsWith('/')) {
      value = value.substring(1);
    }
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    if (value.endsWith('.git')) {
      value = value.substring(0, value.length - 4);
    }
    return value.isEmpty ? null : value;
  }

  @override
  bool operator ==(Object other) =>
      other is RemoteRepo && other.host == host && other.slug == slug;

  @override
  int get hashCode => Object.hash(host, slug);

  @override
  String toString() => 'RemoteRepo($host/$slug)';
}
