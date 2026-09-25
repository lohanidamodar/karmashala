part of 'messages.dart';

// The MCP relay (protocol 3): the daemon takes agents' tool calls and the app
// runs them. JSON inside a length-prefixed string, like the lifecycle feed.

/// client → host: the tools this client runs, as `tools/list` serves them. The
/// connection that sent it last is the one tool calls are forwarded to.
class McpToolsMessage extends HostMessage {
  const McpToolsMessage(this.tools);

  final List<Map<String, Object?>> tools;

  @override
  Frame toFrame() => Frame(
    MessageType.mcpTools,
    0,
    (WireWriter()..str(jsonEncode({'tools': tools}))).take(),
  );

  static McpToolsMessage decode(Frame frame) {
    final map = _object(_decodeJson(WireReader(frame.payload).str()), 'tools');
    final tools = map['tools'];
    if (tools is! List) throw const WireFormatException('tools: not a list');
    return McpToolsMessage([for (final tool in tools) _object(tool, 'tool')]);
  }
}

/// host → client: run [tool] for [callerSessionId] — the session the daemon's
/// token check named, null for an unattributed caller — and answer [callId].
class McpCallMessage extends HostMessage {
  const McpCallMessage({
    required this.callId,
    required this.tool,
    required this.arguments,
    this.callerSessionId,
  });

  final int callId;
  final String tool;
  final Map<String, Object?> arguments;
  final String? callerSessionId;

  @override
  Frame toFrame() => Frame(
    MessageType.mcpCall,
    0,
    (WireWriter()..str(
          jsonEncode({
            'callId': callId,
            'tool': tool,
            'arguments': arguments,
            'callerSessionId': ?callerSessionId,
          }),
        ))
        .take(),
  );

  static McpCallMessage decode(Frame frame) {
    final map = _object(_decodeJson(WireReader(frame.payload).str()), 'call');
    return McpCallMessage(
      callId: _required<int>(map, 'callId'),
      tool: _required<String>(map, 'tool'),
      arguments: _object(map['arguments'], 'arguments'),
      callerSessionId: _optional<String>(map, 'callerSessionId'),
    );
  }
}

/// client → host: how [callId] ended — [result] when it succeeded, else the
/// [error] text the agent is shown.
class McpResultMessage extends HostMessage {
  const McpResultMessage.success(this.callId, this.result) : error = null;
  const McpResultMessage.failure(this.callId, String this.error)
    : result = null;

  final int callId;
  final Object? result;
  final String? error;

  bool get ok => error == null;

  @override
  Frame toFrame() => Frame(
    MessageType.mcpResult,
    0,
    (WireWriter()..str(
          jsonEncode({
            'callId': callId,
            'ok': ok,
            if (ok) 'result': result else 'error': error,
          }),
        ))
        .take(),
  );

  static McpResultMessage decode(Frame frame) {
    final map = _object(_decodeJson(WireReader(frame.payload).str()), 'result');
    final callId = _required<int>(map, 'callId');
    return _required<bool>(map, 'ok')
        ? McpResultMessage.success(callId, map['result'])
        : McpResultMessage.failure(callId, _required<String>(map, 'error'));
  }
}
