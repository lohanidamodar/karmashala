import 'dart:convert';

import '../../../core/process/command_runner.dart';
import '../../../core/process/command_runner_factory.dart';
import '../../environments/data/execution_environment_dao.dart';
import '../../sessions/domain/session_event_types.dart';
import '../../settings/domain/permission_mode.dart';
import '../domain/agent_adapter.dart';
import '../domain/agent_ids.dart';
import 'streaming_agent_session.dart';

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
  ...switch (launch.permissionMode) {
    // Prompting is what an unflagged `agy` does, which is why "ask" adds
    // nothing rather than being unsupported.
    PermissionMode.ask => const <String>[],
    PermissionMode.acceptEdits => const ['--mode', 'accept-edits'],
    PermissionMode.bypass => const ['--dangerously-skip-permissions'],
  },
  if (launch.resumeSessionId != null) ...[
    '--conversation',
    launch.resumeSessionId!,
  ],
];

/// Translates one line of Antigravity CLI output into normalized events.
///
/// This is a **compatibility** adapter: it accepts either structured JSON lines
/// (`{"type": ...}`) or, when a line is not JSON, treats the raw line as agent
/// text. That tolerance is the point — it adapts a looser CLI to the same
/// normalized event model. Raw protocol handling stays here (architecture rule);
/// the mapping is provisional and refinable on live integration.
List<AgentEvent> parseAntigravityMessage(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty) return const [];

  if (trimmed.startsWith('{')) {
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) {
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
String encodeAntigravityUserMessage(String message) => message;

/// Compatibility `AgentAdapter` for the Antigravity CLI.
class AntigravityAdapter implements AgentAdapter {
  AntigravityAdapter({
    required this.runnerFactory,
    required this.environmentDao,
  });

  final CommandRunnerFactory runnerFactory;
  final ExecutionEnvironmentDao environmentDao;

  @override
  String get agentId => AgentIds.antigravity;

  @override
  AgentSession start(AgentLaunch launch) {
    final env = environmentDao.getById(launch.installation.environmentId);
    if (env == null) {
      throw StateError(
        'Unknown environment ${launch.installation.environmentId} for Antigravity.',
      );
    }
    final runner = runnerFactory.forEnvironment(env);
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
