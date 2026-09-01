import 'dart:io';

import 'package:path/path.dart' as p;

/// How an agent is told where Karmashala's own tools are.
///
/// There are two ways to say it, and the difference is which process ends up
/// speaking MCP:
///
/// * **`http`** — the agent dials `POST /mcp` on the app directly. Nothing is
///   spawned, the app is the server, and the URL carries the session's identity
///   (see `LauncherControlServer.mcpUrlFor`). This is the form the app writes,
///   through `SessionMcpConfigs.write`.
/// * **`command`** — the agent spawns `karmashala_mcp.exe`, which translates
///   stdio MCP into the app's private `/rpc` envelope. Nothing in the app
///   configures this; it is offered to a user who wants to point an agent at
///   Karmashala by hand, and the Tools settings page reports whether the
///   executable is there to point at.
///
/// **There are no pre-approval lists here.** Two once were — every served tool,
/// and the read-only subset — and neither had a consumer. Wiring one would have
/// meant handing an interactive agent a tool allow-list beside the
/// `--permission-mode` the *user* picked, so a session started in "ask" would
/// have stopped asking about a set of tools the user never saw. Read-only is
/// also our own annotation rather than an enforced boundary, and the read-only
/// set includes another session's transcript, a phone's screen and a logged-in
/// browser page. Nothing here widens what an agent may do without the user
/// saying so, so the lists are gone rather than parked.
class LauncherMcp {
  const LauncherMcp();

  /// Resolves the bridge executable that ships next to the app, or `null` if it
  /// isn't present (e.g. a dev run without the compiled bridge).
  File? bridgeExecutable() {
    final dir = p.dirname(Platform.resolvedExecutable);
    // `.exe` only on Windows. Asking for one everywhere meant this returned
    // null on macOS and Linux no matter what had been built beside the app, so
    // the stdio bridge could never be offered there even when it was present.
    final name = Platform.isWindows ? 'karmashala_mcp.exe' : 'karmashala_mcp';
    final exe = File(p.join(dir, name));
    return exe.existsSync() ? exe : null;
  }

  /// A Claude-Code-shaped `mcpServers` entry for the app's HTTP endpoint.
  ///
  /// The credential is in the URL rather than in `headers` on purpose: Claude
  /// Code has a standing bug in which configured headers are not attached to
  /// requests for a Streamable HTTP server (anthropics/claude-code#48514), and
  /// a URL is the one field every client sends verbatim. `type: http` is what
  /// the client expects; the spec's own name for the transport,
  /// `streamable-http`, is accepted as an alias.
  static Map<String, Object?> httpServerEntry(String url) => <String, Object?>{
    'type': 'http',
    'url': url,
  };
}
