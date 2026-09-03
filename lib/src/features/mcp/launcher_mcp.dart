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
///   stdio MCP into the app's private `/rpc` envelope. Offered to a user who
///   wants to point an agent at Karmashala by hand, and the Tools settings page
///   reports whether the executable is there to point at — **and it is the form
///   an agent inside WSL is given**, because it is the only one that reaches
///   the app without crossing a network. See [commandServerEntry].
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

  /// A `mcpServers` entry that spawns the stdio bridge at [executablePath].
  ///
  /// **This is how an agent inside a WSL2 distribution reaches the app**, and
  /// the reason is that it is not a network path at all. A distribution has its
  /// own network namespace: `127.0.0.1` there is its own loopback, and the host
  /// side of the Hyper-V virtual switch — the one address of ours it can name —
  /// accepts the connection and then resets the first data segment on the
  /// owner's machine, for a bare PowerShell listener as readily as for this
  /// app. But a *Windows* program launched over WSL interop runs on Windows:
  /// it dials the app's owner-only unix socket the way any local process does.
  /// Measured from inside the owner's distribution: the whole tool surface,
  /// 75 tools, in 42 ms, while `curl` at the switch address was reset.
  ///
  /// So [executablePath] is this app's own bridge, spelled the way the agent
  /// names it — `/mnt/c/…` for a WSL agent, translated by the caller.
  ///
  /// **No credential appears here**, and that is a gain rather than a gap. The
  /// HTTP form carries a per-session token in its URL because an HTTP request
  /// has nothing else to identify itself with. The bridge reads the handshake
  /// token from the application-support directory this app already locks to the
  /// owner, and learns *which session* it belongs to from
  /// `KARMASHALA_SESSION_ID`, which the app stamps on the agent process it
  /// spawns — so the identity is measured off the real process tree rather than
  /// declared by the model, and no token is written into a config file at all.
  ///
  /// The environment crosses because the pane launch names the variable in
  /// `WSLENV`; `agentPtyLaunchFor` already does that, and its comment already
  /// says it is for "a grandchild — the MCP bridge the agent spawns".
  static Map<String, Object?> commandServerEntry(String executablePath) =>
      <String, Object?>{
        'type': 'stdio',
        'command': executablePath,
        'args': const <String>[],
      };
}
