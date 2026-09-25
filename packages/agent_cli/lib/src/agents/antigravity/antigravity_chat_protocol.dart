import 'dart:convert';

import '../../process/command_runner.dart';
import '../../process/command_runner_factory.dart';
import '../../sessions/session_event_types.dart';
import '../adapter/agent_chat_protocol.dart';
import '../domain/agent_ids.dart';
import '../data/streaming_agent_session.dart';

/// Builds the Antigravity CLI arguments for [launch].
///
/// Every flag here is read off `agy --help` (1.1.22) and matches the registry
/// descriptor argument for argument — `agent_registry_test.dart` holds the two
/// to the same goldens, because an adapter that drifts from the descriptor
/// means the same session is launched differently depending on which path
/// started it.
///
/// The previous version of this function emitted `--stdio`, `--yolo` and
/// `--resume`, none of which this CLI has. It was written against a fake
/// process in Loop 10 and never run.
List<String> antigravityLaunchArgs(AgentLaunch launch) => [
  // No base arguments: the CLI is launched bare. `agy` does document a headless
  // `--print --input-format stream-json` mode, but the parser below reads plain
  // text, so claiming that protocol would pair a JSON transport with a reader
  // that does not speak it.
  // Resolved from the descriptor. Prompting is what an unflagged `agy` does,
  // so its "ask" contributes nothing — which is a declared mode with an empty
  // argument list, not an absent one.
  ...launch.permission.arguments,
  if (launch.resumeSessionId != null) ...[
    '--conversation',
    launch.resumeSessionId!,
  ],
];

/// Translates one line of Antigravity CLI output into normalized events.
///
/// Supports the native `stream-json` wire protocol emitted by `agy` in print /
/// streaming mode (`{"event": "init" | "step_update" | "result"}`), as well as
/// compatibility JSON objects (`{"type": ...}`) and plain-text fallback lines.
List<AgentEvent> parseAntigravityMessage(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty) return const [];

  if (trimmed.startsWith('{')) {
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) {
        final event = decoded['event'];
        if (event is String) {
          switch (event) {
            case 'init':
              final cid = decoded['conversation_id'];
              return [
                AgentEvent(SessionEventTypes.agentStatus, {
                  'state': 'started',
                  if (cid is String && cid.isNotEmpty) 'sessionId': cid,
                }),
              ];
            case 'step_update':
              final step = decoded['step_update'];
              if (step is Map<String, dynamic>) {
                final stepType = step['step_type'];
                if (stepType == 'agent_response') {
                  final delta = step['text_delta'];
                  if (delta != null && delta.toString().isNotEmpty) {
                    return [
                      AgentEvent(SessionEventTypes.agentMessage, {
                        'role': 'assistant',
                        'text': delta.toString(),
                      }),
                    ];
                  }
                } else if (stepType == 'tool') {
                  if (step['state'] == 'ACTIVE') {
                    final toolInfo = step['tool_info'];
                    final params = toolInfo is Map<String, dynamic>
                        ? toolInfo['parameters']
                        : null;
                    return [
                      AgentEvent(SessionEventTypes.toolCall, {
                        'name': step['tool_name'] ?? 'unknown_tool',
                        'input': ?params,
                        if (step['step_index'] != null)
                          'id': step['step_index'].toString(),
                      }),
                    ];
                  }
                }
              }
              return const [];
            case 'result':
              final result = decoded['result'];
              if (result is Map<String, dynamic>) {
                if (result['status'] == 'ERROR') {
                  return [
                    AgentEvent(SessionEventTypes.error, {
                      'message': (result['error'] ?? 'unknown error')
                          .toString(),
                    }),
                  ];
                }
                final cid = result['conversation_id'];
                return [
                  AgentEvent(SessionEventTypes.agentStatus, {
                    'state': 'complete',
                    if (cid is String && cid.isNotEmpty) 'sessionId': cid,
                  }),
                ];
              }
              return const [];
            default:
              return const [];
          }
        }

        // Legacy compatibility object format:
        switch (decoded['type']) {
          case 'message':
          case 'assistant':
            return [
              AgentEvent(SessionEventTypes.agentMessage, {
                'role': 'assistant',
                'text': (decoded['text'] ?? decoded['content'] ?? '')
                    .toString(),
              }),
            ];
          case 'status':
            return [
              AgentEvent(SessionEventTypes.agentStatus, {
                'state': decoded['state'],
              }),
            ];
          case 'error':
            return [
              AgentEvent(SessionEventTypes.error, {
                'message': (decoded['message'] ?? 'unknown error').toString(),
              }),
            ];
          default:
            return const [];
        }
      }
    } on FormatException {
      // Fall through to plain-text handling.
    }
  }

  // Compatibility fallback: a non-JSON line is plain agent text.
  return [
    AgentEvent(SessionEventTypes.agentMessage, {
      'role': 'assistant',
      'text': trimmed,
    }),
  ];
}

/// Encodes a user message for the Antigravity CLI as a plain text line.
///
/// **Not** the `{"event":"user"}` stream-json envelope, even though the parser
/// reads that protocol: this descriptor's `baseArguments` are empty, so a pane
/// runs `agy` in its own TUI mode with no `--input-format stream-json`. Wrap
/// the message and the agent receives literal JSON as what the user typed.
/// Claude Code encodes JSON because it asks for that input format; when this
/// descriptor does the same, this may follow.
String encodeAntigravityUserMessage(String message) => message;

/// Compatibility `AgentChatProtocol` for the Antigravity CLI.
class AntigravityChatProtocol implements AgentChatProtocol {
  AntigravityChatProtocol({required this.runnerFor});

  /// The runner that reaches an installation's environment, by id.
  ///
  /// One function in place of the three collaborators this adapter used to
  /// hold — a `CommandRunnerFactory`, an `ExecutionEnvironmentDao` and a
  /// Riverpod-backed resolver — each of which reached a database
  /// (docs/PACKAGE_SPLIT.md §3). The host composes those behind it; refusing
  /// an environment it cannot place is now the resolver's job, and it still
  /// refuses in one place for every launch path.
  final RunnerResolver runnerFor;

  @override
  String get agentId => AgentIds.antigravity;

  @override
  AgentSession start(AgentLaunch launch) {
    final runner = runnerFor(launch.installation.environmentId);
    final request = CommandRequest(
      executable: launch.installation.executable.path,
      arguments: antigravityLaunchArgs(launch),
      workingDirectory: launch.workingDirectory,
    );
    return AntigravityAgentSession(runner.start(request));
  }
}

/// A live Antigravity run. Transport is shared via [StreamingAgentSession].
class AntigravityAgentSession extends StreamingAgentSession {
  AntigravityAgentSession(super.handle);

  @override
  List<AgentEvent> parseLine(String line) => parseAntigravityMessage(line);

  @override
  String encodeUserMessage(String message) =>
      encodeAntigravityUserMessage(message);
}
