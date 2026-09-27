import 'package:karmashala_mcp/catalogue.dart';

import 'tools/server_tools.dart';

/// A tool call that could not be run. Its text is exactly what the agent
/// reads after `Error: `.
class McpToolRelayFailure implements Exception {
  const McpToolRelayFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Tool calls taken by the daemon, every one run here by [tools]. Since slice
/// 5b nothing agent-facing is forwarded to an app: a tool that needs a window
/// asks one through a `ClientIntent` and answers the agent itself, at once,
/// when none is open. A server tool is never timed out here — `session_wait`
/// and `terminal_run` block for as long as their own arguments say.
class McpToolRelay {
  McpToolRelay({ServerTools? tools}) : tools = tools ?? ServerTools();

  /// The tools the server runs.
  final ServerTools tools;

  /// What `tools/list` serves, annotated.
  List<Map<String, dynamic>> catalogue() => annotatedToolSchemas(tools.schemas);

  /// Runs [tool] for [callerSessionId]. Throws [McpToolRelayFailure] for a
  /// tool the server does not serve.
  Future<Object?> call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) {
    final here = tools.call(tool, arguments, callerSessionId);
    if (here != null) return here;
    return Future.error(
      McpToolRelayFailure(
        tools.serves(tool)
            ? 'the server could not run $tool'
            : 'no tool is called $tool',
      ),
    );
  }
}
