import 'dart:convert';

import '../../../core/process/command_runner.dart';
import '../../../core/process/command_runner_factory.dart';
import '../../environments/data/execution_environment_dao.dart';
import '../../sessions/domain/session_event_types.dart';
import '../domain/agent_adapter.dart';
import '../domain/agent_kind.dart';
import 'streaming_agent_session.dart';

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
              AgentEvent('tool.call', {
                'name': block['name'],
                'input': block['input'],
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
  AgentKind get kind => AgentKind.claudeCode;

  @override
  AgentSession start(AgentLaunch launch) {
    final env = environmentDao.getById(launch.installation.environmentId);
    if (env == null) {
      throw StateError(
        'Unknown environment ${launch.installation.environmentId} for Claude Code.',
      );
    }
    final runner = runnerFactory.forEnvironment(env);
    final request = CommandRequest(
      executable: launch.installation.executable.path,
      arguments: const [
        '--input-format',
        'stream-json',
        '--output-format',
        'stream-json',
        '--verbose',
      ],
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
