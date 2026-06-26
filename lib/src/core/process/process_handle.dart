/// A handle to a running process, used for streaming, interactive execution
/// (e.g. an agent's long-lived stdio protocol).
///
/// Obtained from [CommandRunner.start]. All process I/O for features flows
/// through this interface; the concrete `dart:io` implementation lives in
/// `IoProcessHandle`, and tests use a fake.
abstract interface class ProcessHandle {
  /// Line-buffered stdout (decoded text, newline-stripped).
  Stream<String> get stdoutLines;

  /// Line-buffered stderr (decoded text, newline-stripped).
  Stream<String> get stderrLines;

  /// Writes [line] to the process stdin, followed by a newline.
  void writeLine(String line);

  /// Completes with the process exit code.
  Future<int> get exitCode;

  /// Terminates the process.
  Future<void> kill();
}
