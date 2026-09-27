import 'session_lifecycle.dart';

/// What `list` answers with. Every field was observed; the reading's age is the
/// caller's to compute from [observedAt].
class SessionSummary {
  const SessionSummary({
    required this.id,
    required this.argv,
    required this.workingDirectory,
    required this.pid,
    required this.columns,
    required this.rows,
    required this.startedAt,
    required this.observedAt,
    required this.totalBytes,
    required this.firstAvailableOffset,
    required this.lifecycle,
    required this.writeHolder,
  });

  final String id;
  final List<String> argv;
  final String? workingDirectory;
  final int pid;
  final int columns;
  final int rows;
  final DateTime startedAt;

  /// When the host looked. A summary that travelled over SSH is already old.
  final DateTime observedAt;

  final int totalBytes;
  final int firstAvailableOffset;
  final SessionLifecycle lifecycle;
  final String? writeHolder;
}
