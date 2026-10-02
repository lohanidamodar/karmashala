import 'dart:async';
import 'dart:convert';

import 'package:agent_cli/process.dart' show ProcessHandle;

/// The agent process as the runtime sees it: its stdio as byte streams, its
/// stderr as lines, and its exit. Over a [ProcessHandle] in the server; over
/// a fake agent's in-memory streams in tests, so no process runs there.
abstract interface class AcpTransport {
  /// Bytes the agent writes to stdout.
  Stream<List<int>> get output;

  /// Bytes written to the agent's stdin; closing it is closing stdin.
  StreamSink<List<int>> get input;

  /// The agent's stderr, line by line.
  Stream<String> get errorLines;

  Future<int> get exitCode;

  /// Ends the process for good.
  Future<void> kill();

  /// Over the streams an in-memory agent exposes.
  factory AcpTransport.streams({
    required Stream<List<int>> output,
    required StreamSink<List<int>> input,
    required Future<int> exitCode,
    Stream<String>? errorLines,
    Future<void> Function()? kill,
  }) = _StreamTransport;

  /// Over a process the environment's runner started.
  factory AcpTransport.process(ProcessHandle handle) = _ProcessTransport;
}

final class _StreamTransport implements AcpTransport {
  _StreamTransport({
    required this.output,
    required this.input,
    required this.exitCode,
    Stream<String>? errorLines,
    Future<void> Function()? kill,
  }) : errorLines = errorLines ?? const Stream.empty(),
       _kill = kill;

  @override
  final Stream<List<int>> output;
  @override
  final StreamSink<List<int>> input;
  @override
  final Stream<String> errorLines;
  @override
  final Future<int> exitCode;
  final Future<void> Function()? _kill;

  @override
  Future<void> kill() async => _kill?.call();
}

final class _ProcessTransport implements AcpTransport {
  _ProcessTransport(this._handle) : input = _LineSink(_handle);

  final ProcessHandle _handle;

  @override
  final StreamSink<List<int>> input;

  @override
  Stream<List<int>> get output => _handle.stdoutBytes;

  @override
  Stream<String> get errorLines => _handle.stderrLines;

  @override
  Future<int> get exitCode => _handle.exitCode;

  @override
  Future<void> kill() => _handle.kill();
}

/// A [ProcessHandle] writes lines, and the peer writes one message per chunk
/// ending in a newline; this hands each chunk over as that line.
final class _LineSink implements StreamSink<List<int>> {
  _LineSink(this._handle);

  final ProcessHandle _handle;
  final _done = Completer<void>();

  @override
  void add(List<int> event) {
    var text = const Utf8Decoder(allowMalformed: true).convert(event);
    if (text.endsWith('\n')) text = text.substring(0, text.length - 1);
    if (text.isEmpty) return;
    _handle.writeLine(text);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);

  @override
  Future<void> close() async {
    await _handle.closeStdin();
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;
}
