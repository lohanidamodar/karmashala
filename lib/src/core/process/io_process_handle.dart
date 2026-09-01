import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'process_handle.dart';

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
  Future<int> get exitCode => _process.exitCode;

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
