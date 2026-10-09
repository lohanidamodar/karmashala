import 'dart:io';

import 'package:path/path.dart' as p;

/// How an agent is told where Karmashala's own tools are: an `http` URL, or the
/// `command` that spawns the stdio bridge — the only form a WSL agent can use.
class LauncherMcp {
  const LauncherMcp();

  /// Resolves the bridge executable that ships next to the app, or `null` if it
  /// isn't present (e.g. a dev run without the compiled bridge).
  File? bridgeExecutable() {
    final dir = p.dirname(Platform.resolvedExecutable);
    // `.exe` only on Windows: asking for one everywhere returned null on macOS
    // and Linux no matter what had been built beside the app.
    final name = Platform.isWindows ? 'karmashala_mcp.exe' : 'karmashala_mcp';
    final exe = File(p.join(dir, name));
    return exe.existsSync() ? exe : null;
  }

  /// A Claude-Code-shaped `mcpServers` entry for the HTTP endpoint. The
  /// credential is in the URL because configured headers never arrive (#48514).
  static Map<String, Object?> httpServerEntry(String url) => <String, Object?>{
    'type': 'http',
    'url': url,
  };

  /// A `mcpServers` entry that spawns the stdio bridge at [executablePath] —
  /// how an agent inside WSL2 reaches the app, and it carries no credential.
  /// [environment] is laid over the agent's own for the bridge.
  static Map<String, Object?> commandServerEntry(
    String executablePath, {
    Map<String, String> environment = const {},
  }) => <String, Object?>{
    'type': 'stdio',
    'command': executablePath,
    'args': const <String>[],
    if (environment.isNotEmpty) 'env': environment,
  };
}
