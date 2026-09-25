import 'dart:async';

import 'package:agent_cli/src/agents/data/streaming_agent_session.dart';
import 'package:agent_cli/src/agents/adapter/agent_chat_protocol.dart';
import 'package:agent_cli/src/sessions/session_event_types.dart';
import 'package:test/test.dart';

import '../support/fake_command_runner.dart';

/// The transport under every agent session, with the protocol reduced to
/// "one line is one event" so only the transport is under test.
class _LineSession extends StreamingAgentSession {
  _LineSession(super.handle);

  @override
  List<AgentEvent> parseLine(String line) => [
    AgentEvent('line', {'text': line}),
  ];

  @override
  String encodeUserMessage(String message) => message;
}

class _DeadStdinHandle extends FakeProcessHandle {
  @override
  void writeLine(String line) => throw StateError('stdin is closed');
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'a CLI that exits non-zero reports its stderr, not a clean completion',
    () async {
      final handle = FakeProcessHandle();
      final session = _LineSession(Future.value(handle));
      final events = <AgentEvent>[];
      final done = session.events.listen(events.add).asFuture<void>();
      await _settle();

      handle.emitStderr('No conversation found with session ID: 8d3f');
      handle.complete(1);
      await done;

      final error = events.single;
      expect(error.type, SessionEventTypes.error);
      expect(error.data['exitCode'], 1);
      expect(error.data['message'], contains('exited with code 1'));
      expect(
        error.data['message'],
        contains('No conversation found with session ID: 8d3f'),
      );
    },
  );

  test('a clean exit adds no error and closes the events', () async {
    final handle = FakeProcessHandle();
    final session = _LineSession(Future.value(handle));
    final events = <AgentEvent>[];
    final done = session.events.listen(events.add).asFuture<void>();
    await _settle();

    handle.emitStdout('hello');
    handle.emitStderr('a warning nobody needs');
    handle.complete(0);
    await done;

    expect(events.map((e) => e.type), ['line']);
  });

  test('the stderr kept for the report is a bounded tail', () async {
    final handle = FakeProcessHandle();
    final session = _LineSession(Future.value(handle));
    final events = <AgentEvent>[];
    final done = session.events.listen(events.add).asFuture<void>();
    await _settle();

    for (var i = 0; i < 100; i++) {
      handle.emitStderr('e$i');
    }
    handle.complete(2);
    await done;

    final tail = (events.single.data['stderr'] as String).split('\n');
    expect(tail, hasLength(StreamingAgentSession.stderrTailLines));
    expect(tail.first, 'e60');
    expect(tail.last, 'e99');
  });

  test(
    'a fault on the stdout stream is an error event, not an unhandled one',
    () async {
      final handle = FakeProcessHandle();
      final session = _LineSession(Future.value(handle));
      final events = <AgentEvent>[];
      final done = session.events.listen(events.add).asFuture<void>();
      await _settle();

      handle.emitStdout('fine');
      handle.emitStdoutError(
        const FormatException('Unexpected extension byte'),
      );
      handle.complete(0);
      await done;

      expect(events.map((e) => e.type), ['line', SessionEventTypes.error]);
      expect(
        events.last.data['message'],
        contains('Unexpected extension byte'),
      );
    },
  );

  test(
    'a message that cannot be written is reported through the events',
    () async {
      final handle = _DeadStdinHandle();
      final session = _LineSession(Future.value(handle));
      final events = <AgentEvent>[];
      session.events.listen(events.add);
      await _settle();

      await session.send('hello?');

      expect(events.single.type, SessionEventTypes.error);
      expect(events.single.data['message'], contains('stdin is closed'));
    },
  );

  test('a session stopped by its owner reports no exit error', () async {
    final handle = FakeProcessHandle();
    final session = _LineSession(Future.value(handle));
    final events = <AgentEvent>[];
    final done = session.events.listen(events.add).asFuture<void>();
    await _settle();

    await session.stop();
    await done;

    expect(handle.killed, isTrue);
    expect(events, isEmpty, reason: 'exit 137 after our own kill is not news');
  });
}
