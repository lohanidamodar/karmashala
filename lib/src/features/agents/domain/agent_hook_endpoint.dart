import '../../environments/domain/environment_kind.dart';
import 'agent_hook_transport.dart';

/// The most one hook payload may be, in bytes — **the same number at both ends
/// of the wire**.
///
/// The receiver has capped a request body at this since it was written
/// (`LauncherControlServer._readBoundedBody`), and until now that was the only
/// bound anywhere: the generated scripts handed `curl` the whole of stdin,
/// however much of it there was. A hook payload is the agent's own event, and a
/// `PostToolUse` carrying the output of a `Read` is not a theoretical megabyte
/// — so the producer stops at the same number, and a runaway payload is cut or
/// dropped where it is made rather than after it has crossed a socket.
///
/// **One constant rather than two agreeing numbers**, because two drift
/// silently: a producer bounded above the receiver's cap sends payloads that
/// are always refused, and one bounded below it truncates payloads the receiver
/// would have taken. Neither shows up as an error anywhere.
const int kAgentHookPayloadLimitBytes = 1024 * 1024;

/// Where an agent's installed hooks report to, and how.
///
/// The endpoint is hosted by `LauncherControlServer`'s `/agent-hook` route;
/// this type is in `agents/domain` because the hook *installer* is what writes
/// it into an agent's own config, and `agents/` must not depend on `mcp/`.
///
/// **One endpoint, one port, but not one transport.** How an agent reports
/// depends on where that agent runs, and the difference is not cosmetic. A
/// Windows-native or local POSIX pane is a child process on this very machine
/// and shares this process's loopback, so it posts to `127.0.0.1`. A WSL2
/// distribution is a separate VM with its own network namespace: `127.0.0.1`
/// there is the *distribution's* loopback, and the one address of ours it can
/// name — the host side of the Hyper-V virtual switch — is not reliably open.
/// Measured on the owner's machine, from inside the distribution:
///
/// ```
/// 172.18.240.1:47821  connect 0.5ms → RST on the first data segment
/// 172.18.240.1:8787   connect 0.6ms → RST     (and 135, and 445: every port)
/// 192.168.68.59:8787  connect 0.8ms → HTTP/1.1 404   (the same app, answering)
/// ```
///
/// A bare PowerShell `TcpListener` on that address is reset identically, so
/// there is nothing here to fix: the switch is shut for data, by the Hyper-V
/// firewall or by an endpoint-security product, and no line of Dart opens it.
///
/// So a WSL agent is given [AgentHookSpoolTransport] and never a URL: it writes
/// its payload into a directory in its own `$HOME`, which this app reads over
/// `\\wsl.localhost`. Nothing crosses the switch, nothing binds a port inside
/// the distribution, and no token is written into it. See
/// [AgentHookTransport] for the measurements that chose it over the two
/// alternatives.
///
/// An SSH host is another machine entirely and still gets nothing, because the
/// only way to reach it would be to bind an interface the network can see.
class AgentHookEndpoint {
  const AgentHookEndpoint({required this.port, required this.token});

  final int port;
  final String token;

  /// How a hook installed in [environment] delivers, or `null` when nothing
  /// this app offers can be reached from there.
  ///
  /// `null` means the agent gets **nothing**, never a transport that might not
  /// arrive: a hook that is installed and cannot deliver is worse than one that
  /// was skipped, because the skip is reported and the silence is not.
  AgentHookTransport? transportFor(EnvironmentKind environment) =>
      switch (environment) {
        // Both local kinds dial this very process's loopback listener: the
        // agent is a child process on this machine, whatever OS it is.
        EnvironmentKind.windowsNative ||
        EnvironmentKind.localPosix => AgentHookHttpTransport(
          host: '127.0.0.1',
          port: port,
          token: token,
        ),
        // A separate VM. It shares a filesystem with us and not a loopback, so
        // the file is the channel.
        EnvironmentKind.wsl => const AgentHookSpoolTransport(),
        EnvironmentKind.ssh => null,
      };

  /// `host:port` for an agent that reports over HTTP, or `null` for one that
  /// does not report at all — **and for one that reports without a network**.
  ///
  /// Three answers collapsed into two on purpose: every caller asks this in
  /// order to build or describe a URL, and a WSL agent no longer has one.
  String? hostFor(EnvironmentKind environment) {
    final transport = transportFor(environment);
    return transport is AgentHookHttpTransport ? transport.authority : null;
  }

  /// Whether a hook installed in [environment] could actually report.
  bool reaches(EnvironmentKind environment) =>
      transportFor(environment) != null;

  /// The callback URL for one agent's [event], or `null` when [environment]
  /// does not report over HTTP.
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
