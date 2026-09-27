/// One terminal pane the server runs, as its own copy of the screen reads it
/// (slice 5c: every local and WSL pane is the server's since 5a, so no client
/// reports them any more) — what adoption, attribution and worktree cleanup
/// read of a pane. Nothing here knows an agent.
class PaneFacts {
  const PaneFacts({
    required this.paneId,
    required this.live,
    this.workingDirectory,
    this.hostsLaunchedSession = false,
    this.lastCommandId,
    this.lastCommandLine,
    this.lastCommandRunning = true,
    this.tail,
  });

  final String paneId;

  /// Where the pane's shell is, or null when it never said.
  final String? workingDirectory;

  /// Whether a process runs behind the pane.
  final bool live;

  /// Whether the pane was opened to run a session that already has a row —
  /// the *launched* case, never adopted.
  final bool hostsLaunchedSession;

  /// The newest OSC 133 command block's id, or null for a shell with no
  /// integration or one that has run nothing yet.
  final String? lastCommandId;

  /// That block's command line, once the shell said it runs.
  final String? lastCommandLine;

  /// Whether that block still runs. True when the shell is mute.
  final bool lastCommandRunning;

  /// The pane's bottom rows as plain text — only when they were asked for.
  final List<String>? tail;

  PaneFacts withoutTail() => tail == null
      ? this
      : PaneFacts(
          paneId: paneId,
          live: live,
          workingDirectory: workingDirectory,
          hostsLaunchedSession: hostsLaunchedSession,
          lastCommandId: lastCommandId,
          lastCommandLine: lastCommandLine,
          lastCommandRunning: lastCommandRunning,
        );

  @override
  bool operator ==(Object other) =>
      other is PaneFacts &&
      other.paneId == paneId &&
      other.workingDirectory == workingDirectory &&
      other.live == live &&
      other.hostsLaunchedSession == hostsLaunchedSession &&
      other.lastCommandId == lastCommandId &&
      other.lastCommandLine == lastCommandLine &&
      other.lastCommandRunning == lastCommandRunning &&
      _sameRows(other.tail, tail);

  @override
  int get hashCode => Object.hash(
    paneId,
    workingDirectory,
    live,
    hostsLaunchedSession,
    lastCommandId,
    lastCommandLine,
    lastCommandRunning,
    tail == null ? null : Object.hashAll(tail!),
  );

  static bool _sameRows(List<String>? a, List<String>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  String toString() =>
      'PaneFacts($paneId${live ? ' live' : ''}'
      '${lastCommandLine == null ? '' : ' "$lastCommandLine"'})';
}
