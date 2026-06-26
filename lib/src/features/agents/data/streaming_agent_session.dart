import 'dart:async';

import '../../../core/process/process_handle.dart';
import '../../sessions/domain/session_event_types.dart';
import '../domain/agent_adapter.dart';

/// Shared transport for stdio agent sessions that exchange newline-delimited
/// messages over a [ProcessHandle].
///
/// This base owns the *transport* concerns only — process readiness, queuing
/// sends until the process is up, draining stdout, and teardown. Each concrete
/// adapter supplies its own **protocol** mapping via [parseLine] and
/// [encodeUserMessage], so raw protocol handling stays inside the relevant
/// adapter (architecture rule).
abstract class StreamingAgentSession implements AgentSession {
  StreamingAgentSession(Future<ProcessHandle> handle) {
    _attach(handle);
  }

  final StreamController<AgentEvent> _events = StreamController<AgentEvent>();
  final List<String> _pending = [];
  ProcessHandle? _handle;
  bool _stopped = false;

  /// Translates one stdout line into zero or more normalized events.
  List<AgentEvent> parseLine(String line);

  /// Encodes a user message as a single protocol line (no trailing newline).
  String encodeUserMessage(String message);

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

    // Close on stdout EOF (not exitCode) so buffered output drains first.
    handle.stdoutLines.listen(
      (line) {
        for (final event in parseLine(line)) {
          if (!_events.isClosed) _events.add(event);
        }
      },
      onDone: () {
        if (!_events.isClosed) _events.close();
      },
    );

    for (final message in _pending) {
      handle.writeLine(encodeUserMessage(message));
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
    handle.writeLine(encodeUserMessage(message));
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    await _handle?.kill();
    if (!_events.isClosed) await _events.close();
  }
}
