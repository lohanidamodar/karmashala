import 'dart:convert';

import '../../process/command_runner.dart';
import '../../process/command_runner_factory.dart';
import '../../sessions/session_event_types.dart';
import '../domain/agent_adapter.dart';
import '../domain/agent_ids.dart';
import './streaming_agent_session.dart';

/// Builds the Codex `app-server` arguments for [launch], mapping the permission
/// mode to approval/sandbox flags and resuming when a session id is set. Pure /
/// testable; the wire shape is a provisional contract.
List<String> codexLaunchArgs(AgentLaunch launch) => [
  'app-server',
  // Resolved from the descriptor, which is where Codex's two axes and the
  // versions they were read off live. Two approval values have already been
  // retired out from under a hardcoded line here — `on-failure` and
  // `untrusted` — and each time the agent refused to launch.
  ...launch.permission.arguments,
  if (launch.resumeSessionId != null) ...['--resume', launch.resumeSessionId!],
];

/// Translates one line of the Codex **app-server** protocol into a normalized
/// [AgentEvent], or `null` for blank/unknown/ignored lines.
///
/// The protocol is modeled as newline-delimited JSON objects with a `type`
/// field. This mapping is the project's provisional contract; it is intentionally
/// the only place that understands the Codex wire format (raw protocol stays in
/// the adapter, per the architecture rules) and can be refined when integrating
/// the real CLI without touching the engine or UI.
AgentEvent? parseCodexMessage(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty) return null;

  final Map<String, dynamic> message;
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is! Map<String, dynamic>) return null;
    message = decoded;
  } on FormatException {
    return null;
  }

  switch (message['type']) {
    case 'thread.started':
      final thread = message['thread'];
      final id = thread is Map ? thread['id'] : message['thread_id'];
      return AgentEvent(SessionEventTypes.agentStatus, {
        'state': 'started',
        if (id is String) 'sessionId': id,
      });
    case 'agent_message':
      return AgentEvent(SessionEventTypes.agentMessage, {
        'role': 'assistant',
        'text': (message['text'] ?? '').toString(),
      });
    case 'status':
      return AgentEvent(SessionEventTypes.agentStatus, {
        'state': message['state'],
      });
    case 'tool_call':
      return AgentEvent(SessionEventTypes.toolCall, {
        'name': message['name'],
        'arguments': message['arguments'],
      });
    case 'task_complete':
      return AgentEvent(SessionEventTypes.agentStatus, {'state': 'complete'});
    case 'error':
      return AgentEvent(SessionEventTypes.error, {
        'message': (message['message'] ?? 'unknown error').toString(),
      });
    default:
      return null;
  }
}

/// Encodes a user message as a Codex app-server protocol line (no newline).
String encodeCodexUserMessage(String message) =>
    jsonEncode({'type': 'user_message', 'text': message});

/// `AgentAdapter` for the Codex CLI's app-server protocol.
///
/// Launches `codex app-server` in the installation's environment and exposes a
/// [CodexAgentSession] that speaks the protocol. All raw protocol handling is
/// confined here and in [CodexAgentSession].
class CodexAdapter implements AgentAdapter {
  CodexAdapter({required this.runnerFor});

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
  String get agentId => AgentIds.codex;

  @override
  AgentSession start(AgentLaunch launch) {
    final runner = runnerFor(launch.installation.environmentId);
    final request = CommandRequest(
      executable: launch.installation.executable.path,
      arguments: codexLaunchArgs(launch),
      workingDirectory: launch.workingDirectory,
    );
    return CodexAgentSession(runner.start(request));
  }
}

/// A live Codex run over a [ProcessHandle]'s stdio. Transport is shared via
/// [StreamingAgentSession]; only the Codex protocol mapping lives here.
class CodexAgentSession extends StreamingAgentSession {
  CodexAgentSession(super.handle);

  @override
  List<AgentEvent> parseLine(String line) {
    final event = parseCodexMessage(line);
    return event == null ? const [] : [event];
  }

  @override
  String encodeUserMessage(String message) => encodeCodexUserMessage(message);
}
