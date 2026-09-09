/// How a hook that fired inside one environment gets its payload to this app.
///
/// There is more than one answer because there is more than one *boundary*, and
/// the boundary is not always a network this app can rely on. A Windows-native
/// pane and this process share a loopback, so the agent posts to a URL. A WSL2
/// distribution does not: it is a separate VM with its own network namespace,
/// and the only address of ours it can name is the host side of the Hyper-V
/// virtual switch — which on the owner's machine completes the TCP handshake
/// and then resets the first data segment, for our port and for ports 135 and
/// 445 alike, and does the same to a bare PowerShell `TcpListener` with no Dart
/// anywhere in the picture. Nothing in this repository can open that door.
///
/// So the WSL transport stops trying to cross it. Measured on that machine,
/// from inside the distribution, per hook:
///
/// | transport | cost to the agent | delivered |
/// | --- | --- | --- |
/// | `curl` at the switch address (what shipped) | 2008 ms | no |
/// | `/mnt/c/…/curl.exe` over WSL interop at Windows' own loopback | 227 ms | yes |
/// | write a file into a spool directory | 3.6 ms | yes |
///
/// The last row is [AgentHookSpoolTransport], and the reason it wins is the
/// rule `AgentHookReceiver` states and this table measures: *a hook must never
/// block the agent that fired it.* Claude Code fires `PreToolUse` and
/// `PostToolUse` on every tool call, so the interop row is nearly half a second
/// of the user's turn per tool; the spool row is a write that cannot fail
/// slowly. Its cost lands on **this** app instead, as one directory listing per
/// distribution per tick over `\\wsl.localhost` — 0.68 ms measured, warm.
sealed class AgentHookTransport {
  const AgentHookTransport();
}

/// The agent `POST`s its payload to a URL and authenticates with a bearer
/// token: the original transport, kept unchanged for every environment that
/// shares a loopback with this process.
final class AgentHookHttpTransport extends AgentHookTransport {
  const AgentHookHttpTransport({
    required this.host,
    required this.port,
    required this.token,
  });

  final String host;
  final int port;

  /// The status-only credential. Public to anything running as this user by
  /// construction — see `LauncherControlServer`'s threat model — and the only
  /// reason it exists is that loopback TCP has no peer credentials.
  final String token;

  String get authority => '$host:$port';
}

/// The agent writes its payload into a directory this app can read, and this
/// app reads it. No socket, no port, **and no token**.
///
/// The absence of the token is the point rather than an omission. A bearer
/// token buys one thing — proof to the *receiver* that the sender is not a
/// stranger who happened to bind the port. There is no port here and no
/// stranger who could bind one: the spool lives inside the store home this app
/// wrote the script and the endpoint file into, on a filesystem reachable only
/// by the distribution's own user and by this Windows account. Carrying a
/// credential anyway would put a secret at rest in a distribution's `$HOME` to
/// authenticate a channel that has no impostor.
///
/// The directory is named by the installer, which owns every generated file's
/// name; this type carries no path so that `domain/` keeps knowing nothing
/// about where `data/` puts things.
final class AgentHookSpoolTransport extends AgentHookTransport {
  const AgentHookSpoolTransport();
}
