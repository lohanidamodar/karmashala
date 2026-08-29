/// Where an agent's installed hooks call back to, and the token they must send.
///
/// The endpoint is hosted by `LauncherControlServer`'s `/agent-hook` route;
/// this type is in `agents/domain` because the hook *installer* is what writes
/// it into an agent's own config, and `agents/` must not depend on `mcp/`.
class AgentHookEndpoint {
  const AgentHookEndpoint({required this.port, required this.token});

  final int port;
  final String token;

  Uri uriFor({required String agentId, required String event}) => Uri.parse(
    'http://127.0.0.1:$port/agent-hook?agent=$agentId&event=$event',
  );
}
