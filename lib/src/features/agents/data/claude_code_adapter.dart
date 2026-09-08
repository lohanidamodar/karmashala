import 'dart:convert';

import '../../../core/process/command_runner.dart';
import '../../../core/process/command_runner_factory.dart';
import '../../environments/application/environment_resolver.dart';
import '../../environments/data/execution_environment_dao.dart';
import '../../sessions/domain/session_event_types.dart';
import '../domain/agent_adapter.dart';
import '../domain/agent_ids.dart';
import 'streaming_agent_session.dart';

/// Builds the Claude Code CLI arguments for [launch], mapping the permission
/// mode to `--permission-mode` and resuming when a session id is set. Pure /
/// testable; the wire shape is a provisional contract.
List<String> claudeLaunchArgs(AgentLaunch launch) => [
  '--input-format',
  'stream-json',
  '--output-format',
  'stream-json',
  '--verbose',
  // Resolved from the descriptor rather than restated here. This used to be a
  // second copy of the flag table, kept honest only by a golden test; the
  // descriptor is now the only place that knows Claude Code's six modes.
  ...launch.permission.arguments,
  if (launch.resumeSessionId != null) ...['--resume', launch.resumeSessionId!],
  if (launch.mcpConfigPath != null) ...['--mcp-config', launch.mcpConfigPath!],
  // No `--allowedTools`. It was here, always empty, and the only list that
  // could have filled it named every tool the app serves — so wiring it would
  // have carved a silent exception out of the `--permission-mode` above.
  if (launch.appendSystemPrompt != null) ...[
    '--append-system-prompt',
    launch.appendSystemPrompt!,
  ],
];

/// Translates one line of Claude Code's `stream-json` output into zero or more
/// normalized [AgentEvent]s.
///
/// Claude Code emits newline-delimited JSON objects with a `type`. An
/// `assistant` message carries a `message.content` list whose blocks may be
/// `text` (→ agent message) or `tool_use` (→ tool call) — hence a list result.
/// This mapping is the project's provisional contract and is the only place that
/// understands the Claude wire format (raw protocol stays in the adapter).
List<AgentEvent> parseClaudeMessage(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty) return const [];

  final Map<String, dynamic> message;
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is! Map<String, dynamic>) return const [];
    message = decoded;
  } on FormatException {
    return const [];
  }

  switch (message['type']) {
    case 'system':
      return [
        AgentEvent(SessionEventTypes.agentStatus, {
          'state': message['subtype'] ?? 'system',
          if (message['session_id'] is String)
            'sessionId': message['session_id'] as String,
        }),
      ];
    case 'assistant':
      final content = (message['message']?['content'] as List?) ?? const [];
      final events = <AgentEvent>[];
      for (final block in content) {
        if (block is! Map) continue;
        switch (block['type']) {
          case 'text':
            events.add(
              AgentEvent(SessionEventTypes.agentMessage, {
                'role': 'assistant',
                'text': (block['text'] ?? '').toString(),
              }),
            );
          case 'tool_use':
            events.add(
              AgentEvent(SessionEventTypes.toolCall, {
                'name': block['name'],
                'input': block['input'],
                // Carried so a later result can be matched back to this call.
                // Nothing consumes it yet; without it, correlating a subagent's
                // completion would be guesswork over ordering.
                if (block['id'] != null) kToolUseIdKey: block['id'],
              }),
            );
        }
      }
      return events;
    case 'result':
      return [
        AgentEvent(SessionEventTypes.agentStatus, {
          'state': message['subtype'] ?? 'result',
        }),
      ];
    case 'error':
      return [
        AgentEvent(SessionEventTypes.error, {
          'message': (message['message'] ?? 'unknown error').toString(),
        }),
      ];
    default:
      return const [];
  }
}

/// Encodes a user message as a Claude Code `stream-json` input line.
String encodeClaudeUserMessage(String message) => jsonEncode({
  'type': 'user',
  'message': {
    'role': 'user',
    'content': [
      {'type': 'text', 'text': message},
    ],
  },
});

/// `AgentAdapter` for Claude Code's `stream-json` protocol.
class ClaudeCodeAdapter implements AgentAdapter {
  ClaudeCodeAdapter({
    required this.runnerFactory,
    required this.environmentDao,
  });

  final CommandRunnerFactory runnerFactory;
  final ExecutionEnvironmentDao environmentDao;

  @override
  String get agentId => AgentIds.claudeCode;

  @override
  AgentSession start(AgentLaunch launch) {
    // The one resolver, so an agent that cannot be placed refuses in the
    // same words as every other launch path.
    final env = ExecutionEnvironmentResolver(
      environments: environmentDao,
      runners: runnerFactory,
    ).resolve(launch.installation.environmentId).require;
    final runner = runnerFactory.forEnvironment(env);
    final request = CommandRequest(
      executable: launch.installation.executable.path,
      arguments: claudeLaunchArgs(launch),
      workingDirectory: launch.workingDirectory,
    );
    return ClaudeCodeAgentSession(runner.start(request));
  }
}

/// A live Claude Code run. Transport is shared via [StreamingAgentSession]; only
/// the Claude protocol mapping lives here.
class ClaudeCodeAgentSession extends StreamingAgentSession {
  ClaudeCodeAgentSession(super.handle);

  @override
  List<AgentEvent> parseLine(String line) => parseClaudeMessage(line);

  @override
  String encodeUserMessage(String message) => encodeClaudeUserMessage(message);
}
