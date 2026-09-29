/// Raised when a `git` invocation fails (non-zero exit), carrying git's stderr.
class GitException implements Exception {
  GitException(this.message);
  final String message;
  @override
  String toString() => 'GitException: $message';
}

/// A streamed git command was stopped because it was cancelled.
class GitCancelled implements Exception {
  GitCancelled(this.outputTail);
  final List<String> outputTail;
  @override
  String toString() => 'GitCancelled';
}

/// How a streamed git command ended.
class GitStreamResult {
  const GitStreamResult({
    required this.exitCode,
    required this.outputTail,
    this.stalled = false,
  });

  final int exitCode;

  /// The last lines it printed, ANSI-stripped, progress folded.
  final List<String> outputTail;

  /// It printed nothing for the idle bound and was killed.
  final bool stalled;

  bool get ok => exitCode == 0 && !stalled;
}
