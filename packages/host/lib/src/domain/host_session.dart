import 'dart:async';
import 'dart:typed_data';

import '../pty/pty.dart';
import 'output_backlog.dart';
import 'session_lifecycle.dart';
import 'session_recorder.dart';
import 'write_token.dart';

/// A chunk of output with the absolute offset it starts at, so a client can
/// store one number and reattach exactly.
class OutputChunk {
  const OutputChunk(this.offset, this.bytes);
  final int offset;
  final Uint8List bytes;
  int get nextOffset => offset + bytes.length;
}

/// One pty, its backlog, and its single writer. The session outlives every
/// client of it, and nothing here is driven by a timer.
class HostSession {
  HostSession({
    required this.id,
    required this.request,
    required PtyHandle pty,
    required this.startedAt,
    int backlogCapacityBytes = OutputBacklog.defaultCapacityBytes,
    this.recorder,
  }) : _pty = pty,
       backlog = OutputBacklog(capacityBytes: backlogCapacityBytes),
       columns = request.columns,
       rows = request.rows,
       _lifecycle = const SessionRunning() {
    _pty.output.listen(
      _onOutput,
      onError: (Object error) => _readFault ??= '$error',
      onDone: _onOutputDone,
    );
    unawaited(
      _pty.exitCode.then(
        (code) => _finish(
          code < 0
              ? SessionEndedWithoutCode(
                  DateTime.now(),
                  'the child could not be reaped${_readFault == null ? '' : '; $_readFault'}',
                )
              : SessionExited(code, DateTime.now()),
        ),
      ),
    );
  }

  /// The first fault the pty reader reported, kept for the end reason: a
  /// session that ends without a code should say why if the pty knows.
  String? _readFault;

  /// A session read back from disk: no process, and [lifecycle] is whatever the
  /// record said. Nothing is invented, so a lost session keeps no exit code.
  HostSession.restored({
    required this.id,
    required this.request,
    required this.startedAt,
    required OutputBacklog restoredBacklog,
    required SessionLifecycle lifecycle,
  }) : _pty = const _NoProcess(),
       recorder = null,
       backlog = restoredBacklog,
       columns = request.columns,
       rows = request.rows,
       _lifecycle = lifecycle,
       _outputDone = true,
       _released = true {
    // Closed at once, so an attaching client gets the replay and then an end.
    unawaited(_live.close());
    _ended.complete(lifecycle);
  }

  final String id;
  final PtySpawnRequest request;
  final DateTime startedAt;
  final OutputBacklog backlog;

  /// Where the ring is mirrored so it outlives this process. Null for a restored
  /// session: replaying into its own record would double every byte.
  final SessionRecorder? recorder;
  final WriteToken token = WriteToken();
  final PtyHandle _pty;

  int columns;
  int rows;

  final _live = StreamController<OutputChunk>.broadcast(sync: true);
  final _ended = Completer<SessionLifecycle>();
  SessionLifecycle _lifecycle;
  var _outputDone = false;
  var _released = false;

  SessionLifecycle get lifecycle => _lifecycle;
  int get pid => _pty.pid;
  Future<SessionLifecycle> get ended => _ended.future;

  void _onOutput(Uint8List bytes) {
    if (bytes.isEmpty) return;
    final offset = backlog.totalBytes;
    backlog.add(bytes);
    recorder?.record(bytes);
    // Synchronous broadcast, so a listener attached in the same turn as the
    // backlog read cannot miss the chunk between the two.
    if (_live.hasListener) _live.add(OutputChunk(offset, bytes));
  }

  void _onOutputDone() {
    if (!_live.isClosed) _live.close();
    // Here rather than in [_finish]: the exit can complete between two queued
    // chunks, and only the end of output means no byte can still arrive.
    _outputDone = true;
    recorder?.close();
    _releasePty();
  }

  void _finish(SessionLifecycle end) {
    if (_lifecycle.hasEnded) return;
    _lifecycle = end;
    recorder?.ended(end);
    if (!_ended.isCompleted) _ended.complete(end);
    _releasePty();
  }

  /// Gives the OS its handles back once both halves of the pty are done — never
  /// either alone, or a queued chunk or a microtask-away exit code is lost.
  void _releasePty() {
    if (!_outputDone || !_lifecycle.hasEnded) return;
    unawaited(_closePty());
  }

  /// Closes at most once: [terminate] and [_releasePty] both reach it, and a
  /// handle must not be closed twice.
  Future<void> _closePty() async {
    if (_released) return;
    _released = true;
    await _pty.close();
  }

  /// Replay from [offset], then live, with no gap and no repeat: the backlog
  /// read and the live subscription happen in one synchronous `onListen` turn.
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

  ClaimRefusal? resize(
    String clientId,
    int newColumns,
    int newRows,
    DateTime now,
  ) {
    final refusal = _requireToken(clientId, now);
    if (refusal != null) return refusal;
    columns = newColumns;
    rows = newRows;
    _pty.resize(newColumns, newRows);
    recorder?.resized(backlog.totalBytes, newColumns, newRows);
    return null;
  }

  ClaimRefusal? _requireToken(String clientId, DateTime now) {
    final holder = token.holder;
    if (holder == null) return ClaimRefusal.unclaimed(now);
    if (holder.clientId != clientId) return ClaimRefusal.heldBy(holder, now);
    return null;
  }

  void signal(int number) => _pty.kill(number);

  static const int _sigkill = 9;

  /// Ends the session for good; a client disconnect must never call this. The
  /// real exit code wins over "terminated" — [reapWithin] is a bound, not a poll,
  /// and a child still there when it expires gets SIGKILL and the bound again.
  Future<SessionLifecycle> terminate({
    int signal = 15,
    Duration reapWithin = const Duration(seconds: 5),
  }) async {
    if (_lifecycle.hasEnded) {
      await _closePty();
      return _lifecycle;
    }
    _pty.kill(signal);
    var end = await _reapedWithin(reapWithin);
    if (end == null && signal != _sigkill) {
      // An interactive shell ignores SIGTERM; this is the one nothing ignores.
      _pty.kill(_sigkill);
      end = await _reapedWithin(reapWithin);
    }
    if (end == null) {
      _finish(
        SessionEndedWithoutCode(
          DateTime.now(),
          'signalled $signal${signal == _sigkill ? '' : ', then $_sigkill,'} and not '
          'reaped within ${reapWithin.inMilliseconds}ms of each',
        ),
      );
      end = _lifecycle;
    }
    await _closePty();
    recorder?.close();
    if (!_live.isClosed) await _live.close();
    return end;
  }

  Future<SessionLifecycle?> _reapedWithin(Duration bound) => ended
      .then<SessionLifecycle?>((end) => end)
      .timeout(bound, onTimeout: () => null);
}

/// The absence of a process, so no reader of [HostSession] needs a nullable pty.
/// [exitCode] never completes: the lifecycle came from the record.
class _NoProcess implements PtyHandle {
  const _NoProcess();

  @override
  int get pid => 0;

  @override
  Stream<Uint8List> get output => const Stream<Uint8List>.empty();

  @override
  Future<int> get exitCode => Completer<int>().future;

  @override
  void write(Uint8List bytes) {}

  @override
  void resize(int columns, int rows) {}

  @override
  void kill([int signal = 15]) {}

  @override
  Future<void> close() async {}
}
