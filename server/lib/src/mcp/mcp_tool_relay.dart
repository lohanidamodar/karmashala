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
  McpToolRelay({ServerTools? tools, this.operatorGranted, this.checkpointOwner})
    : tools = tools ?? ServerTools();

  /// Whether the person let session [sessionId] operate Karmashala. Null
  /// grants every session — a relay with no store to ask.
  final bool Function(String sessionId)? operatorGranted;

  /// The session a checkpoint belongs to, or null when there is none.
  final String? Function(String checkpointId)? checkpointOwner;

  /// Why a call may not run yet, in the words the caller reads, having
  /// recorded it for a person's approval; null when it may. Asks of every
  /// authenticated caller and holds only the bot's (`BotApprovals.hold`). Set
  /// by `serve`, since it answers through what the relay's own tools built.
  String? Function(
    String tool,
    Map<String, dynamic> arguments,
    String callerSessionId,
  )?
  approvalGate;

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
    // A call that reaches other sessions or agents, from a session the person
    // has not let operate Karmashala, is refused before it runs. A caller in
    // no session is the person's own tooling, set up by them outside any
    // session. [callerSessionId] is the authenticated caller, so a `sessionId`
    // argument naming it is the caller's own session.
    final granted = operatorGranted;
    if (callerSessionId != null &&
        granted != null &&
        tools.serves(tool) &&
        mcpToolNeedsOperatorGrant(
          tool,
          arguments,
          callerSessionId,
          checkpointOwner: checkpointOwner,
        ) &&
        !granted(callerSessionId)) {
      return Future.error(McpToolRelayFailure(mcpOperatorRefusal(tool)));
    }
    // Beside the grant: never held open, so nothing here waits for a person.
    if (callerSessionId != null && tools.serves(tool)) {
      final held = approvalGate?.call(tool, arguments, callerSessionId);
      if (held != null) return Future.error(McpToolRelayFailure(held));
    }
    return _run(tool, arguments, callerSessionId);
  }

  /// Runs a call a person approved, as [callerSessionId], past both gates:
  /// only `BotApprovals` calls this, with exactly what it recorded.
  Future<Object?> runApproved(
    String tool,
    Map<String, dynamic> arguments,
    String callerSessionId,
  ) => _run(tool, arguments, callerSessionId);

  Future<Object?> _run(
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
