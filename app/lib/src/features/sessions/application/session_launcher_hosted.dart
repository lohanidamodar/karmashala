part of 'session_launcher.dart';

/// Where [SessionLauncher.endRunning] ended a session: in the pane it names,
/// or — no pane of ours showing it — at this machine's session host.
class EndedSession {
  const EndedSession.pane(String this.paneId);
  const EndedSession.atHost() : paneId = null;

  final String? paneId;
  bool get atHost => paneId == null;
}

/// Sessions this machine's session host is running with no pane of ours
/// showing them — an automation the daemon started while the app was closed,
/// or one whose pane was closed: opened by **attaching** a pane to the host's
/// session, ended by asking the host, and never resumed over.
extension SessionHostedVerbs on SessionLauncher {
  /// Whether this machine's host says it is running [sessionId] and no pane of
  /// ours is showing it. A session asked to end is not held, whatever the
  /// feed still says, until the feed catches up.
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
  /// pane attached to the host's session. False when neither runs it; nothing
  /// is started and nothing resumed.
  Future<bool> show(String sessionId) async =>
      reveal(sessionId) || await attachHosted(sessionId) != null;

  /// Opens a pane on the session the host is running for [sessionId], or null
  /// when it runs none (or a pane of ours already shows it — [reveal] that).
  ///
  /// The pane is the one any launch of this row would open — same
  /// `AgentPaneLaunch`, same `karmashala_<id>` host session — so the host
  /// attaches it rather than starting anything, and afterwards it is an
  /// ordinary host-backed pane: the row names it, hooks and status follow it,
  /// ending it ends the session, and the layout restores it after a restart.
  /// Its command line is the row's resume, which runs only if the session
  /// ended in the moment between this check and the attach.
  Future<SessionLaunchResult?> attachHosted(String sessionId) async {
    if (!heldByHostOnly(sessionId)) return null;
    final session = _ref.read(sessionsDataProvider).getById(sessionId);
    if (session == null) return null;
    final repository = _ref
        .read(workspaceDataProvider)
        .repository(session.repositoryId);
    final installation = _ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId);
    if (repository == null || installation == null) {
      _log.warning(
        'The session host is running $sessionId, but its '
        '${repository == null ? 'repository' : 'agent installation'} is no '
        'longer in the workspace, so no pane can be opened on it.',
      );
      return null;
    }
    final agentId = installation.agentId;
    final descriptor = _ref.read(agentRegistryProvider).byId(agentId);
    final request = SessionLaunchRequest(
      repository: repository,
      installation: installation,
      title: session.title,
      purpose: SessionPurpose.existingSession,
      resumeExternalSessionId: session.externalSessionId,
      existingWorktree: session.worktree,
      workingDirectory: session.workingDirectory,
      surface: SessionSurface.pane,
    );
    final result = await _startInPane(
      session,
      request,
      descriptor,
      permissionFor(
        agentId,
        SessionPurpose.existingSession,
        sessionMode: session.permissionMode,
      ),
      resolveSessionModel(
        sessionModelId: session.modelId,
        defaultModelId: defaultModelFor(agentId),
      ).modelId,
      session.workingDirectory ?? session.worktree ?? repository.path,
      false,
      null,
      null,
      null,
    );
    _log.info(
      'Attached pane ${result.paneId} to $sessionId, which the session host '
      'was running with no pane: nothing started, nothing resumed.',
    );
    _ref.read(selectedSessionIdProvider.notifier).select(sessionId);
    _publish(SessionChange.moved(sessionId));
    return result;
  }

  /// Ends the agent behind [sessionId]: its live pane, else the host's session
  /// when no pane of ours shows it. Null when nothing is running it. The row's
  /// status is the host's to write once the process is gone.
  Future<EndedSession?> endRunning(String sessionId) async {
    final paneId = livePaneFor(sessionId);
    if (paneId != null) {
      _ref.read(terminalSessionsControllerProvider.notifier).endSession(paneId);
      return EndedSession.pane(paneId);
    }
    if (!heldByHostOnly(sessionId)) return null;
    final end = _ref.read(hostedSessionEnderProvider);
    if (end == null) return null;
    _endingOnHost.add(sessionId);
    try {
      await end(sessionId);
    } on Object {
      _endingOnHost.remove(sessionId);
      rethrow;
    }
    _log.info('Ended $sessionId at the session host; no pane showed it.');
    return const EndedSession.atHost();
  }

  /// The row a resume of [request]'s conversation would continue, when the
  /// host is running it with no pane: that launch attaches instead.
  Session? _hostHeldRowFor(SessionLaunchRequest request) {
    final externalId = request.resumeExternalSessionId;
    if (externalId == null || externalId.isEmpty) return null;
    if (request.restartSessionId != null ||
        request.forkExternalSessionId != null) {
      return null;
    }
    for (final candidate
        in _ref
            .read(sessionsDataProvider)
            .getAllByExternalSessionId(externalId)) {
      if (candidate.isArchived) continue;
      if (candidate.repositoryId != request.repository.id) continue;
      if (heldByHostOnly(candidate.id)) return candidate;
    }
    return null;
  }

  /// Whether a failed attempt to open or resume [session] may write its
  /// status: not when this machine's host knows the row, whose lifecycle status
  /// is the daemon's alone to write — a session running there is not failed
  /// because a second process could not be started beside it.
  bool _mayRecordLaunchFailure(Session session) =>
      !_ref.read(sessionFollowsHostFactsProvider)(session);
}
