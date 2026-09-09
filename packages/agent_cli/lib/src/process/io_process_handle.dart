import 'dart:async';
import 'dart:convert';
import 'dart:io';

import './process_handle.dart';

/// [ProcessHandle] backed by a `dart:io` [Process]. Shared by the Windows and
/// WSL runners — the only difference between them is how the process is spawned.
class IoProcessHandle implements ProcessHandle {
  IoProcessHandle(this._process);

  final Process _process;

  @override
  Stream<String> get stdoutLines =>
      _process.stdout.transform(utf8.decoder).transform(const LineSplitter());

  @override
  Stream<List<int>> get stdoutBytes => _process.stdout;

  @override
  Stream<String> get stderrLines =>
      _process.stderr.transform(utf8.decoder).transform(const LineSplitter());

  @override
  void writeLine(String line) {
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
    _process.kill();
    try {
      // Give the process a moment to exit; force-kill if it ignores SIGTERM.
      await _process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      _process.kill(ProcessSignal.sigkill);
      await _process.exitCode;
    }
  }
}
