import 'dart:async';
import 'dart:typed_data';

/// What to start on a pty, in full: nothing about a session's process is
/// inferred later, so a restarted host reads the same request back.
class PtySpawnRequest {
  const PtySpawnRequest({
    required this.argv,
    this.workingDirectory,
    this.environment = const {},
    this.removedEnvironment = const {},
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

  /// Names deleted from the host process's own environment before
  /// [environment] is laid over it — so a variable `serve` inherited is
  /// withheld too, not only one the client sent.
  final Set<String> removedEnvironment;
  final int columns;
  final int rows;

  PtySpawnRequest copyWith({int? columns, int? rows}) => PtySpawnRequest(
    argv: argv,
    workingDirectory: workingDirectory,
    environment: environment,
    removedEnvironment: removedEnvironment,
    columns: columns ?? this.columns,
    rows: rows ?? this.rows,
  );
}

/// A child's environment: [base] minus [removed], with [overrides] laid last,
/// so a name the client supplies is one the child really gets.
///
/// [caseInsensitive] is Windows: `path` replaces `Path` rather than joining it,
/// and removing `ANTHROPIC_API_KEY` removes `anthropic_api_key` too.
Map<String, String> layeredEnvironment({
  required Map<String, String> base,
  Map<String, String> overrides = const {},
  Set<String> removed = const {},
  required bool caseInsensitive,
}) {
  String fold(String name) => caseInsensitive ? name.toLowerCase() : name;
  final withheld = {for (final name in removed) fold(name)};
  final merged = <String, String>{};
  final spelling = <String, String>{}; // folded name -> the spelling in use
  void put(String key, String value) {
    final existing = spelling[fold(key)];
    if (existing != null) merged.remove(existing);
    spelling[fold(key)] = key;
    merged[key] = value;
  }

  base.forEach((key, value) {
    if (!withheld.contains(fold(key))) put(key, value);
  });
  overrides.forEach(put);
  return merged;
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
