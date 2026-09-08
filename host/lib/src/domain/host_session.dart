import 'dart:async';
import 'dart:typed_data';

import '../pty/pty.dart';
import 'output_backlog.dart';
import 'session_lifecycle.dart';
import 'write_token.dart';

/// A chunk of output with the absolute offset it starts at, so a client can
/// store one number and reattach exactly.
class OutputChunk {
  const OutputChunk(this.offset, this.bytes);
  final int offset;
  final Uint8List bytes;
  int get nextOffset => offset + bytes.length;
}

/// One pty, its backlog, and its single writer.
///
/// The session outlives every client of it. Nothing here is driven by a timer:
/// output arrives because the pty produced it, and [lifecycle] changes because
/// the child was reaped.
class HostSession {
  HostSession({
    required this.id,
    required this.request,
    required PtyHandle pty,
    required this.startedAt,
    int backlogCapacityBytes = OutputBacklog.defaultCapacityBytes,
  }) : _pty = pty,
       backlog = OutputBacklog(capacityBytes: backlogCapacityBytes),
       columns = request.columns,
       rows = request.rows {
    _pty.output.listen(_onOutput, onError: (Object _) {}, onDone: _onOutputDone);
    unawaited(
      _pty.exitCode.then(
        (code) => _finish(
          code < 0
              ? SessionEndedWithoutCode(DateTime.now(), 'the child could not be reaped')
              : SessionExited(code, DateTime.now()),
        ),
      ),
    );
  }

  final String id;
  final PtySpawnRequest request;
  final DateTime startedAt;
  final OutputBacklog backlog;
  final WriteToken token = WriteToken();
  final PtyHandle _pty;

  int columns;
  int rows;

  final _live = StreamController<OutputChunk>.broadcast(sync: true);
  final _ended = Completer<SessionLifecycle>();
  SessionLifecycle _lifecycle = const SessionRunning();

  SessionLifecycle get lifecycle => _lifecycle;
  int get pid => _pty.pid;
  Future<SessionLifecycle> get ended => _ended.future;

  void _onOutput(Uint8List bytes) {
    if (bytes.isEmpty) return;
    final offset = backlog.totalBytes;
    backlog.add(bytes);
    // Synchronous broadcast, so a listener attached in the same turn as the
    // backlog read cannot miss the chunk between the two.
    if (_live.hasListener) _live.add(OutputChunk(offset, bytes));
  }

  void _onOutputDone() {
    if (!_live.isClosed) _live.close();
  }

  void _finish(SessionLifecycle end) {
    if (_lifecycle.hasEnded) return;
    _lifecycle = end;
    if (!_ended.isCompleted) _ended.complete(end);
  }

  /// Replay from [offset], then live, with no gap and no repeat.
  ///
  /// The backlog read and the live subscription happen in one synchronous turn
  /// inside `onListen`, which is the whole reason a reattach neither loses a
  /// byte nor shows one twice.
  Stream<OutputChunk> readFrom(int offset) {
    late final StreamController<OutputChunk> controller;
    StreamSubscription<OutputChunk>? subscription;
    controller = StreamController<OutputChunk>(
      onListen: () {
        final slice = backlog.since(offset);
        if (!slice.isEmpty) {
          controller.add(OutputChunk(slice.offset, slice.bytes));
        }
        if (_live.isClosed) {
          controller.close();
          return;
        }
        subscription = _live.stream.listen(
          controller.add,
          onDone: controller.close,
          onError: controller.addError,
        );
      },
      onCancel: () async => subscription?.cancel(),
    );
    return controller.stream;
  }

  /// Writing and resizing need the token; refusals name the holder.
  ClaimRefusal? write(String clientId, Uint8List bytes, DateTime now) {
    final refusal = _requireToken(clientId, now);
    if (refusal != null) return refusal;
    _pty.write(bytes);
    return null;
  }

  ClaimRefusal? resize(String clientId, int newColumns, int newRows, DateTime now) {
    final refusal = _requireToken(clientId, now);
    if (refusal != null) return refusal;
    columns = newColumns;
    rows = newRows;
    _pty.resize(newColumns, newRows);
    return null;
  }

  ClaimRefusal? _requireToken(String clientId, DateTime now) {
    final holder = token.holder;
    if (holder == null) return ClaimRefusal.unclaimed(now);
    if (holder.clientId != clientId) return ClaimRefusal.heldBy(holder, now);
    return null;
  }

  void signal(int number) => _pty.kill(number);

  /// Ends the session for good. A client disconnect must never call this —
  /// that is the entire point of the host.
  ///
  /// The real exit code is preferred over "terminated": killing the child still
  /// produces a wait status, and [reapWithin] is a failure bound, not a poll.
  /// Only when the reaping does not happen is the code recorded as unknown.
  Future<SessionLifecycle> terminate({
    int signal = 15,
    Duration reapWithin = const Duration(seconds: 5),
  }) async {
    if (_lifecycle.hasEnded) {
      await _pty.close();
      return _lifecycle;
    }
    _pty.kill(signal);
    final end = await ended.timeout(reapWithin, onTimeout: () {
      _finish(
        SessionEndedWithoutCode(
          DateTime.now(),
          'signalled $signal and not reaped within ${reapWithin.inSeconds}s',
        ),
      );
      return _lifecycle;
    });
    await _pty.close();
    if (!_live.isClosed) await _live.close();
    return end;
  }
}
