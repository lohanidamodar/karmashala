import 'dart:async';
import 'dart:convert';
import 'dart:io';

import './process_handle.dart';
import './process_tree.dart';

/// [ProcessHandle] backed by a `dart:io` [Process]. Shared by the Windows and
/// WSL runners — the only difference between them is how the process is spawned.
class IoProcessHandle implements ProcessHandle {
  /// With [endsTree], [kill] closes stdin, waits [grace] for an exit of its
  /// own, and only then has [treeKiller] end the process and its descendants.
  IoProcessHandle(
    this._process, {
    this.endsTree = false,
    this.grace = const Duration(seconds: 3),
    this.treeKiller = const SystemProcessTreeKiller(),
  }) {
    // With nobody listening, a write to a dead child is an uncaught zone error
    // while writeLine returns normally; listened to, it is the next write's.
    _process.stdin.done.then<void>(
      (_) {},
      onError: (Object error) => _stdinFailure = error,
    );
  }

  final Process _process;
  final bool endsTree;
  final Duration grace;
  final ProcessTreeKiller treeKiller;
  Object? _stdinFailure;

  /// A code-page byte in an otherwise UTF-8 stream is one wrong character, not
  /// a dropped chunk and a stack trace.
  static const _lenientUtf8 = Utf8Decoder(allowMalformed: true);

  @override
  Stream<String> get stdoutLines =>
      _process.stdout.transform(_lenientUtf8).transform(const LineSplitter());

  @override
  Stream<List<int>> get stdoutBytes => _process.stdout;

  @override
  Stream<String> get stderrLines =>
      _process.stderr.transform(_lenientUtf8).transform(const LineSplitter());

  /// Throws a [StateError] once stdin is known to be gone; the write that
  /// discovered it is lost, and the exit code says the rest.
  @override
  void writeLine(String line) {
    final failure = _stdinFailure;
    if (failure != null) {
      throw StateError('the process no longer reads stdin: $failure');
    }
    _process.stdin.writeln(line);
  }

  @override
  Future<void> closeStdin() async {
    try {
      await _process.stdin.close();
    } on Object {
      // Already closed, or the process is gone. Either way there is nothing
      // left to close.
    }
  }

  /// The started process's id.
  int get pid => _process.pid;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  Future<void> interrupt() async {
    // Windows has no SIGINT to send: `Process.kill` maps every signal but
    // SIGKILL onto TerminateProcess there. Nothing that needs an interrupt
    // runs on Windows — simctl is macOS-only — so this is honest rather than
    // silently different.
    _process.kill(ProcessSignal.sigint);
    try {
      await _process.exitCode.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      await kill();
    }
  }

  @override
  Future<void> kill() async {
    if (endsTree) return _endTree();
    _process.kill();
    try {
      // Give the process a moment to exit; force-kill if it ignores SIGTERM.
      await _process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      _process.kill(ProcessSignal.sigkill);
      await _process.exitCode;
    }
  }

  Future<void> _endTree() async {
    // A child that never reads would hold the close forever.
    await closeStdin().timeout(const Duration(seconds: 1), onTimeout: () {});
    if (await _exitsWithin(grace)) return;
    try {
      await treeKiller.killTree(_process.pid);
    } on Object {
      // The top process is still killed below.
    }
    if (await _exitsWithin(const Duration(seconds: 5))) return;
    _process.kill(ProcessSignal.sigkill);
    await _exitsWithin(const Duration(seconds: 5));
  }

  Future<bool> _exitsWithin(Duration bound) => _process.exitCode
      .then((_) => true)
      .timeout(bound, onTimeout: () => false);
}
