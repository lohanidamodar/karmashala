part of 'session_launcher.dart';

/// Where [SessionLauncher.endRunning] ended a session: in the pane it names,
/// or — no pane of ours showing it — at the server.
class EndedSession {
  const EndedSession.pane(String this.paneId);
  const EndedSession.atHost() : paneId = null;

  final String? paneId;
  bool get atHost => paneId == null;
}

/// Sessions the server runs with no pane of ours showing them — one an agent,
/// a phone or an automation started, or one whose tab was closed: shown by
/// **attaching** a pane to the terminal the server runs it in, ended by
/// asking the server, never started twice.
extension SessionHostedVerbs on SessionLauncher {
  /// Whether the server says it runs [sessionId] and no pane of ours is
  /// showing it. A session asked to end is not held, whatever the feed still
  /// says, until the feed catches up.
  bool heldByHostOnly(String? sessionId) {
    if (sessionId == null || livePaneFor(sessionId) != null) return false;
    final running = _ref.read(sessionRunningOnHostProvider)(sessionId);
    if (_endingOnHost.contains(sessionId)) {
      if (!running) _endingOnHost.remove(sessionId);
      return false;
    }
    return running;
  }

  /// Brings [sessionId] into view wherever it runs: its live pane, else a new
  /// pane attached to the server's terminal. False when neither runs it.
  Future<bool> show(String sessionId) async =>
      reveal(sessionId) || await attachHosted(sessionId) != null;

  /// Opens a pane on the terminal the server runs [sessionId] in, or null
  /// when it runs none (or a pane of ours already shows it — [reveal] that).
  Future<SessionLaunchResult?> attachHosted(String sessionId) async {
    if (!heldByHostOnly(sessionId)) return null;
    return resumeAtServer(sessionId);
  }

  /// Continues [sessionId] at the server — its own conversation, in its own
  /// row — and shows what came back: a pane attached to the terminal, or the
  /// chat tab of an agent spoken to over a protocol. One already running is
  /// answered as it is, never started twice. Without [openTab] nothing opens
  /// or takes focus here.
  Future<SessionLaunchResult> resumeAtServer(
    String sessionId, {
    bool openTab = true,
  }) async {
    final started = await _ref.read(sessionsClientProvider).resume(sessionId);
    return _show(started, openTab: openTab);
  }

  /// Ends the agent behind [sessionId]: its live pane, else the server's
  /// terminal when no pane of ours shows it. Null when nothing is running it.
  Future<EndedSession?> endRunning(String sessionId) async {
    final paneId = livePaneFor(sessionId);
    if (paneId != null) {
      _ref.read(terminalSessionsControllerProvider.notifier).endSession(paneId);
      return EndedSession.pane(paneId);
    }
    if (!heldByHostOnly(sessionId)) return null;
    _endingOnHost.add(sessionId);
    try {
      if (!await _ref.read(sessionsClientProvider).end(sessionId)) {
        _endingOnHost.remove(sessionId);
        return null;
      }
    } on Object {
      _endingOnHost.remove(sessionId);
      rethrow;
    }
    _log.info('Ended $sessionId at the server; no pane showed it.');
    return const EndedSession.atHost();
  }
}
