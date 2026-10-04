/// Whether [toolName] is a Karmashala call that starts a child session:
/// `subagent_run` or `open_new_session`, however the agent names it — a
/// CLI's `mcp__karmashala__…`, codex-acp's `Tool: karmashala/…`, a bare name.
bool isDelegationToolName(String toolName) => _launch.hasMatch(toolName);

final _launch = RegExp(r'(?:^|[^A-Za-z0-9])(?:subagent_run|open_new_session)$');
final _childId = RegExp(r'"(?:childSessionId|sessionId)"\s*:\s*"([^"]+)"');

/// The child a launch call started, read from its answer; null before it
/// answered, or when it was refused.
String? delegatedChildIdOf(String? output) =>
    output == null ? null : _childId.firstMatch(output)?.group(1);
