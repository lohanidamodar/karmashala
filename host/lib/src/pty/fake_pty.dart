import 'dart:async';
import 'dart:typed_data';

import 'pty.dart';

/// A [PtyLauncher] with no operating system behind it, so every layer above
/// the pty is testable on Windows. It records rather than simulates: a test
/// asserts what was written and resized, and drives output and exit itself.
class FakePtyLauncher implements PtyLauncher {
  FakePtyLauncher({this.onStart});

  final void Function(FakePtyHandle handle)? onStart;
  final started = <PtySpawnRequest>[];
  final handles = <FakePtyHandle>[];
  int nextPid = 1000;

  /// Set to throw instead of starting, for the refusal paths.
  PtyException? failWith;

  @override
  PtyHandle start(PtySpawnRequest request) {
    final failure = failWith;
    if (failure != null) throw failure;
    started.add(request);
    final handle = FakePtyHandle(nextPid++, request);
    handles.add(handle);
    onStart?.call(handle);
    return handle;
  }
}

class FakePtyHandle implements PtyHandle {
  FakePtyHandle(this.pid, this.request);

  @override
  final int pid;
  final PtySpawnRequest request;

  final writes = <Uint8List>[];
  final resizes = <(int, int)>[];
  final signals = <int>[];
  var closeCount = 0;

  final _output = StreamController<Uint8List>.broadcast();
  final _exit = Completer<int>();

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  void write(Uint8List bytes) => writes.add(bytes);

  @override
  void resize(int columns, int rows) => resizes.add((columns, rows));

  @override
  void kill([int signal = 15]) => signals.add(signal);

  @override
  Future<void> close() async {
    closeCount++;
    if (!_output.isClosed) await _output.close();
  }

  /// Everything a test writes as if it came from the child.
  void emit(List<int> bytes) {
    if (!_output.isClosed) _output.add(Uint8List.fromList(bytes));
  }

  void finish(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
    if (!_output.isClosed) _output.close();
  }
}
