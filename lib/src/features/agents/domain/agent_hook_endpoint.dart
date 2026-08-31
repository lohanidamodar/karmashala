import '../../environments/domain/environment_kind.dart';

/// Where an agent's installed hooks call back to, and the token they must send.
///
/// The endpoint is hosted by `LauncherControlServer`'s `/agent-hook` route;
/// this type is in `agents/domain` because the hook *installer* is what writes
/// it into an agent's own config, and `agents/` must not depend on `mcp/`.
///
/// **One endpoint, one port, but not one URL.** The address an agent must dial
/// depends on where that agent runs, and the difference is not cosmetic: a
/// WSL2 distribution is a separate Linux VM with its own network namespace, so
/// `127.0.0.1` inside it is the *distribution's* loopback and a connection to
/// the host's is refused outright. Measured from this machine against a
/// two-door server on one port, using the command [uriFor] is built into:
///
/// ```
/// $ curl … http://127.0.0.1:56566/agent-hook       # from WSL → refused
/// $ curl … http://172.18.240.1:56566/agent-hook    # from WSL → {"ok":true}
/// ```
///
/// So [wslHost] is handed **in** by whoever bound the socket, rather than
/// resolved here: finding the switch address means reading the host's network
/// interfaces, which is `mcp/`'s job and is exactly the dependency this type's
/// home is chosen to avoid.
class AgentHookEndpoint {
  const AgentHookEndpoint({
    required this.port,
    required this.token,
    this.wslHost,
  });

  final int port;
  final String token;

  /// The host side of the WSL virtual switch, as an address a process inside a
  /// distribution can dial — or `null` on a machine with no such switch, and on
  /// a run where nothing was bound there.
  ///
  /// Null means WSL agents get **nothing**, never a loopback fallback: a hook
  /// that is installed and cannot arrive is worse than one that was skipped,
  /// because the skip is reported and the silence is not.
  final String? wslHost;

  /// `host:port` for an agent running in [environment], or `null` when no
  /// address this app binds can be reached from there.
  String? hostFor(EnvironmentKind environment) => switch (environment) {
    EnvironmentKind.windowsNative => '127.0.0.1:$port',
    EnvironmentKind.wsl => wslHost == null ? null : '$wslHost:$port',
    // Another machine entirely. The only way to reach it would be to bind an
    // interface the network can see.
    EnvironmentKind.ssh => null,
  };

  /// Whether a hook installed in [environment] could actually call back.
  bool reaches(EnvironmentKind environment) => hostFor(environment) != null;

  /// The callback URL for one agent's [event], or `null` when [environment]
  /// cannot reach this app at all.
  Uri? uriFor({
    required String agentId,
    required String event,
    required EnvironmentKind environment,
  }) {
    final host = hostFor(environment);
    if (host == null) return null;
    return Uri.parse('http://$host/agent-hook?agent=$agentId&event=$event');
  }
}
