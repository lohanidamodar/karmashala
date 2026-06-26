import 'dart:async';
import 'dart:convert';

import '../../../core/process/command_runner.dart';
import '../../../core/process/command_runner_factory.dart';
import '../../../core/process/process_handle.dart';
import '../../environments/data/execution_environment_dao.dart';
import '../../sessions/domain/session_event_types.dart';
import '../domain/agent_adapter.dart';
import '../domain/agent_kind.dart';

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
      return AgentEvent('tool.call', {
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
  CodexAdapter({required this.runnerFactory, required this.environmentDao});

  final CommandRunnerFactory runnerFactory;
  final ExecutionEnvironmentDao environmentDao;

  @override
  AgentKind get kind => AgentKind.codex;

  @override
  AgentSession start(AgentLaunch launch) {
    final env = environmentDao.getById(launch.installation.environmentId);
    if (env == null) {
      throw StateError(
        'Unknown environment ${launch.installation.environmentId} for Codex.',
      );
    }
    final runner = runnerFactory.forEnvironment(env);
    final request = CommandRequest(
      executable: launch.installation.executable.path,
      arguments: const ['app-server'],
      workingDirectory: launch.workingDirectory,
    );
    return CodexAgentSession(runner.start(request));
  }
}

/// A live Codex run over a [ProcessHandle]'s stdio.
class CodexAgentSession implements AgentSession {
  CodexAgentSession(Future<ProcessHandle> handle) {
    _attach(handle);
  }

  final StreamController<AgentEvent> _events = StreamController<AgentEvent>();
  final List<String> _pending = [];
  ProcessHandle? _handle;
  bool _stopped = false;

  @override
  Stream<AgentEvent> get events => _events.stream;

  Future<void> _attach(Future<ProcessHandle> handleFuture) async {
    final ProcessHandle handle;
    try {
      handle = await handleFuture;
    } catch (error) {
      if (!_events.isClosed) {
        _events.add(AgentEvent(SessionEventTypes.error, {'message': '$error'}));
        await _events.close();
      }
      return;
    }
    if (_stopped) {
      await handle.kill();
      return;
    }
    _handle = handle;

    // Closing on stdout's onDone (EOF) — not on exitCode — so all buffered
    // output is drained before the event stream closes.
    handle.stdoutLines.listen(
      (line) {
        final event = parseCodexMessage(line);
        if (event != null && !_events.isClosed) _events.add(event);
      },
      onDone: () {
        if (!_events.isClosed) _events.close();
      },
    );

    for (final message in _pending) {
      handle.writeLine(encodeCodexUserMessage(message));
    }
    _pending.clear();
  }

  @override
  Future<void> send(String message) async {
    final handle = _handle;
    if (handle == null) {
      _pending.add(message); // queued until the process is ready
      return;
    }
    handle.writeLine(encodeCodexUserMessage(message));
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    await _handle?.kill();
    if (!_events.isClosed) await _events.close();
  }
}
