import 'dart:async';
import 'dart:collection';

import '../../process/process_handle.dart';
import '../../sessions/session_event_types.dart';
import '../domain/agent_adapter.dart';

/// Shared transport for stdio agent sessions that exchange newline-delimited
/// messages over a [ProcessHandle].
///
/// This base owns the *transport* concerns only — process readiness, queuing
/// sends until the process is up, draining stdout and stderr, and teardown.
/// Each concrete adapter supplies its own **protocol** mapping via [parseLine]
/// and [encodeUserMessage], so raw protocol handling stays inside the relevant
/// adapter (architecture rule).
abstract class StreamingAgentSession implements AgentSession {
  StreamingAgentSession(Future<ProcessHandle> handle) {
    _attach(handle);
  }

  /// How many stderr lines are kept for the error a failed exit reports.
  static const int stderrTailLines = 40;

  /// How long the stderr pipe may lag the exit before the tail is taken as is.
  static const Duration stderrSettle = Duration(seconds: 2);

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
      _fail('$error');
      await _close();
      return;
    }
    if (_stopped) {
      await handle.kill();
      return;
    }
    _handle = handle;

    // stderr is drained whether or not anyone reads it: a full pipe blocks a
    // verbose child forever, and its tail is the only account of a failed exit.
    final stderrTail = ListQueue<String>();
    final stderrDone = Completer<void>();
    handle.stderrLines.listen(
      (line) {
        stderrTail.addLast(line);
        if (stderrTail.length > stderrTailLines) stderrTail.removeFirst();
      },
      onError: (Object _) {},
      onDone: stderrDone.complete,
      cancelOnError: true,
    );

    final stdoutDone = Completer<void>();
    handle.stdoutLines.listen(
      (line) {
        for (final event in parseLine(line)) {
          if (!_events.isClosed) _events.add(event);
        }
      },
      onError: (Object error) {
        _fail('The agent\'s output could not be read: $error');
        stdoutDone.complete(); // cancelled on error, so no done follows
      },
      onDone: stdoutDone.complete,
      cancelOnError: true,
    );

    for (final message in _pending) {
      _write(handle, message);
    }
    _pending.clear();

    // Closed on exit, not on stdout EOF: a CLI that refuses to start says so on
    // stderr and exits non-zero after writing nothing at all to stdout.
    await stdoutDone.future;
    final code = await handle.exitCode;
    await stderrDone.future.timeout(stderrSettle, onTimeout: () {});
    if (code != 0 && !_stopped) {
      final tail = stderrTail.join('\n').trim();
      _fail(
        'The agent exited with code $code${tail.isEmpty ? '.' : ':\n$tail'}',
        {'exitCode': code, if (tail.isNotEmpty) 'stderr': tail},
      );
    }
    await _close();
  }

  void _fail(String message, [Map<String, Object?> more = const {}]) {
    if (_events.isClosed) return;
    _events.add(
      AgentEvent(SessionEventTypes.error, {'message': message, ...more}),
    );
  }

  Future<void> _close() async {
    // Not awaited: closing a single-subscription controller nobody has
    // listened to never completes, and a session stopped early is that case.
    if (!_events.isClosed) unawaited(_events.close());
  }

  void _write(ProcessHandle handle, String message) {
    try {
      handle.writeLine(encodeUserMessage(message));
    } on Object catch (error) {
      _fail('The message could not be delivered to the agent: $error');
    }
  }

  @override
  Future<void> send(String message) async {
    final handle = _handle;
    if (handle == null) {
      _pending.add(message); // queued until the process is ready
      return;
    }
    _write(handle, message);
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    await _handle?.kill();
    await _close();
  }
}
