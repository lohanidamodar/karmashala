import 'package:riverpod/riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens a page outside the app.
typedef ExternalUrlOpener = Future<bool> Function(String url);

/// How the app opens a web page; a provider so a test can record what a link
/// would have opened.
final openExternalUrlProvider = Provider<ExternalUrlOpener>(
  (ref) => openInBrowser,
);

/// Opens [url] in the user's browser, refusing anything that is not http(s) —
/// so a malformed or hostile `origin` cannot turn a click into a launched
/// scheme handler.
Future<bool> openInBrowser(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return false;
  }
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// The browsable `https://` URL for a git remote, or null when there is not
/// one — `git@host:owner/repo.git` is scp syntax and `Uri.parse` misreads it.
String? webUrlForRemote(String remote) {
  final value = remote.trim();
  if (value.isEmpty) return null;

  String strip(String path) =>
      path.endsWith('.git') ? path.substring(0, path.length - 4) : path;
  bool looksLikeHost(String host) =>
      host.contains('.') && RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(host);

  // scp syntax: [user@]host:path — the shape `git clone` prints for SSH
  // remotes, and the one `Uri` cannot read.
  final scp = RegExp(r'^(?:[^@/]+@)?([^/:]+):(?!//)(.+)$').firstMatch(value);
  if (scp != null) {
    final host = scp.group(1)!;
    final path = strip(scp.group(2)!).replaceFirst(RegExp(r'^/+'), '');
    if (!looksLikeHost(host) || path.isEmpty) return null;
    return 'https://$host/$path';
  }

  final uri = Uri.tryParse(value);
  if (uri == null || !looksLikeHost(uri.host) || uri.path.isEmpty) return null;
  return switch (uri.scheme) {
    'http' ||
    'https' ||
    'ssh' ||
    'git' => 'https://${uri.host}${strip(uri.path)}',
    _ => null,
  };
}

/// The host [remote] lives on — `github.com` for both its SSH and HTTPS
/// spellings — or null when it names no web host (a local path, a bare name).
String? remoteHostOf(String remote) {
  final url = webUrlForRemote(remote);
  return url == null ? null : Uri.parse(url).host.toLowerCase();
}
