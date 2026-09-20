import 'dart:async';
import 'dart:typed_data';

/// What to start on a pty, in full: nothing about a session's process is
/// inferred later, so a restarted host reads the same request back.
class PtySpawnRequest {
  const PtySpawnRequest({
    required this.argv,
    this.workingDirectory,
    this.environment = const {},
    this.columns = 80,
    this.rows = 24,
  });

  /// argv[0] is the executable; it is resolved on PATH by the launcher.
  final List<String> argv;
  final String? workingDirectory;

  /// **Overrides**, on both platforms: laid over the host process's own
  /// environment rather than replacing it. A block with no `SystemRoot` cannot
  /// load a DLL on Windows, and one with no `PATH` or `HOME` cannot run a shell
  /// anywhere.
  final Map<String, String> environment;
  final int columns;
  final int rows;

  PtySpawnRequest copyWith({int? columns, int? rows}) => PtySpawnRequest(
    argv: argv,
    workingDirectory: workingDirectory,
    environment: environment,
    columns: columns ?? this.columns,
    rows: rows ?? this.rows,
  );
}

/// A running child attached to a pseudo-terminal. Nothing here polls: a
/// blocking read in its own isolate feeds [output], and its end-of-file is what
/// [exitCode] waits behind.
abstract class PtyHandle {
  int get pid;

  /// Raw bytes the child wrote. Never decoded here — the host relays bytes.
  Stream<Uint8List> get output;

  /// Completes when the child has been reaped. A signalled child reports
  /// `128 + signal`, so a caller never decodes a wait status.
  Future<int> get exitCode;

  void write(Uint8List bytes);
  void resize(int columns, int rows);
  void kill([int signal = 15]);

  /// Releases the master fd and stops the reader. Safe to call twice.
  Future<void> close();
}

/// The seam that keeps everything above this file testable on Windows.
abstract class PtyLauncher {
  /// Throws [PtyException] when the pty pair or the child cannot be created.
  PtyHandle start(PtySpawnRequest request);
}

class PtyException implements Exception {
  const PtyException(this.message, {this.errno});
  final String message;
  final int? errno;

  @override
  String toString() => errno == null
      ? 'PtyException: $message'
      : 'PtyException: $message (errno $errno)';
}
