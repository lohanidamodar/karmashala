/// A handle to a running process, used for streaming, interactive execution
/// (e.g. an agent's long-lived stdio protocol).
///
/// Obtained from [CommandRunner.start]. All process I/O for features flows
/// through this interface; the concrete `dart:io` implementation lives in
/// `IoProcessHandle`, and tests use a fake.
abstract interface class ProcessHandle {
  /// Line-buffered stdout (decoded text, newline-stripped).
  ///
  /// **Listen to this or to [stdoutBytes], never both.** A process's stdout is
  /// one stream and can be subscribed to once; the second listener throws.
  Stream<String> get stdoutLines;

  /// Raw stdout, undecoded.
  ///
  /// For output that is not text and must not be run through a UTF-8 decoder
  /// or split on newlines: an encoded video stream, an archive, an image. The
  /// live-view backends read H.264 access units off here, and decoding those
  /// as text would corrupt every frame that happened to contain a `0x0A`.
  ///
  /// **Listen to this or to [stdoutLines], never both** — see above.
  Stream<List<int>> get stdoutBytes;

  /// Line-buffered stderr (decoded text, newline-stripped).
  Stream<String> get stderrLines;

  /// Writes [line] to the process stdin, followed by a newline.
  void writeLine(String line);

  /// Completes with the process exit code.
  Future<int> get exitCode;

  /// Terminates the process.
  Future<void> kill();
}
