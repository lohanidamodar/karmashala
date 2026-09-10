import 'dart:io';

import 'package:path/path.dart' as p;

/// How an agent is told where Karmashala's own tools are: **`http`**, dialling
/// `POST /mcp` on the app with the session's identity in the URL, or
/// **`command`**, spawning `karmashala_mcp` to translate stdio into the app's
/// private `/rpc` envelope — the only form that reaches the app without crossing
/// a network, and so the one an agent inside WSL is given.
///
/// **There are no pre-approval lists here.** Two once were and neither had a
/// consumer; wiring one would hand an interactive agent a tool allow-list beside
/// the `--permission-mode` the *user* picked.
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

  /// A Claude-Code-shaped `mcpServers` entry for the app's HTTP endpoint.
  ///
  /// The credential is in the URL rather than in `headers` on purpose: Claude
  /// Code has a standing bug in which configured headers are not attached to
  /// requests for a Streamable HTTP server (anthropics/claude-code#48514), and a
  /// URL is the one field every client sends verbatim.
  static Map<String, Object?> httpServerEntry(String url) => <String, Object?>{
    'type': 'http',
    'url': url,
  };

  /// A `mcpServers` entry that spawns the stdio bridge at [executablePath].
  ///
  /// **This is how an agent inside WSL2 reaches the app**, because it is not a
  /// network path at all: a Windows program launched over interop runs on
  /// Windows and dials the owner-only socket like any local process. Measured
  /// from inside the owner's distribution, 75 tools in 42 ms, while `curl` at
  /// the switch address was reset.
  ///
  /// **No credential appears here**: the bridge reads the handshake token from
  /// the directory this app locks to the owner, and learns which session it
  /// serves from `KARMASHALA_SESSION_ID`, which the pane launch names in
  /// `WSLENV`.
  static Map<String, Object?> commandServerEntry(String executablePath) =>
      <String, Object?>{
        'type': 'stdio',
        'command': executablePath,
        'args': const <String>[],
      };
}
