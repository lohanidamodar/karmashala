import 'dart:io';

/// The path the host takes agent hooks on — the same one the app served, so a
/// hook script installed for either posts to it unchanged.
const String kAgentHookPath = '/agent-hook';

/// `<hostDir>/hook.endpoint`: where this host takes agent hooks and the token
/// they must carry, for the app to point its hook installs at.
class HookEndpoint {
  const HookEndpoint({required this.port, required this.token});

  final int port;
  final String token;

  Uri get url => Uri.parse('http://127.0.0.1:$port$kAgentHookPath');

  String encode() => 'url=$url\ntoken=$token\n';

  /// Null for text that names no loopback port or no token.
  static HookEndpoint? parse(String text) {
    String? url;
    String? token;
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('url=')) url = trimmed.substring(4);
      if (trimmed.startsWith('token=')) token = trimmed.substring(6);
    }
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri == null || !uri.hasPort || token == null || token.isEmpty) {
      return null;
    }
    return HookEndpoint(port: uri.port, token: token);
  }

  /// Null when the file is missing or unreadable: no host has served hooks
  /// from this directory.
  static HookEndpoint? read(String path) {
    try {
      return parse(File(path).readAsStringSync());
    } on FileSystemException {
      return null;
    }
  }

  /// Staged owner-only before the token goes in, then renamed over [path].
  /// On Windows the host directory's inherited ACL is what closes it.
  Future<void> write(String path) async {
    final staged = File('$path.tmp');
    if (staged.existsSync()) staged.deleteSync();
    staged.createSync(recursive: true);
    if (!Platform.isWindows) {
      final result = await Process.run('chmod', ['600', staged.path]);
      if (result.exitCode != 0) {
        staged.deleteSync();
        throw FileSystemException(
          'chmod 600 failed: ${result.stderr}',
          staged.path,
        );
      }
    }
    staged.writeAsStringSync(encode(), flush: true);
    staged.renameSync(path);
  }
}
