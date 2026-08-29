import 'dart:async';

import '../../sessions/domain/session_event_types.dart';
import '../domain/agent_adapter.dart';
import '../domain/agent_ids.dart';

/// A fake agent used to exercise the session engine end-to-end before any real
/// protocol exists (Loop 6). It greets on start and echoes each message back.
///
/// Pure Dart — it spawns no process, so the engine and event flow can be tested
/// deterministically.
class FakeAgentAdapter implements AgentAdapter {
  FakeAgentAdapter({
    this.agentId = AgentIds.claudeCode,
    this.greeting = 'Fake agent ready.',
    this.autoComplete = false,
  });

  @override
  final String agentId;

  final String greeting;

  /// When true, the session ends on its own right after greeting (simulating an
  /// agent that finishes a one-shot run).
  final bool autoComplete;

  @override
  AgentSession start(AgentLaunch launch) =>
      FakeAgentSession(greeting, autoComplete: autoComplete);
}

/// The live session produced by [FakeAgentAdapter].
class FakeAgentSession implements AgentSession {
  FakeAgentSession(String greeting, {bool autoComplete = false}) {
    // Buffered on a single-subscription controller, delivered once the engine
    // listens.
    _controller.add(
      AgentEvent(SessionEventTypes.agentMessage, {
        'role': 'assistant',
        'text': greeting,
      }),
    );
    if (autoComplete) _controller.close();
  }

  final StreamController<AgentEvent> _controller =
      StreamController<AgentEvent>();

  @override
  Stream<AgentEvent> get events => _controller.stream;

  @override
  Future<void> send(String message) async {
    if (_controller.isClosed) return;
    _controller.add(
      AgentEvent(SessionEventTypes.agentMessage, {
        'role': 'assistant',
        'text': 'Echo: $message',
      }),
    );
  }

  @override
  Future<void> stop() async {
    if (!_controller.isClosed) await _controller.close();
  }
}
