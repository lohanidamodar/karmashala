part of 'session_launcher.dart';

/// Is it already running, may a second process have it, was it ever written —
/// asked here for every surface, so a refusal cannot drift apart per call site.
extension SessionResumeGuards on SessionLauncher {
  // --- is it already running? ------------------------------------------------

  /// The pane [sessionId] is running in **right now**, or `null`. A detached
  /// pane is live; one restored from disk is not, whatever its buffer shows.
  String? livePaneFor(String? sessionId) => sessionId == null
      ? null
      : _ref.read(paneSessionsProvider).paneOf(sessionId, where: _isLive);

  /// The pane [sessionId] was **restored** into and has never run, or `null`:
  /// it holds this session's own scrollback but nothing running behind it.
  String? dormantPaneFor(String? sessionId) => sessionId == null
      ? null
      : _ref.read(paneSessionsProvider).paneOf(sessionId, where: _isRestored);

  /// The session we are already running conversation [externalSessionId] in:
  /// in a pane of ours, or at this machine's host with no pane ([show] opens
  /// either). **Every** row with that id: `external_session_id` has no
  /// `UNIQUE` index.
  Session? runningSessionWithExternalId(String? externalSessionId) {
    if (externalSessionId == null || externalSessionId.isEmpty) return null;
    for (final candidate
        in _ref
            .read(sessionsDataProvider)
            .getAllByExternalSessionId(externalSessionId)) {
      if (livePaneFor(candidate.id) != null) return candidate;
      if (heldByHostOnly(candidate.id)) return candidate;
    }
    return null;
  }

  /// Brings the pane [sessionId] is running in back into view and selects it;
  /// false when nothing of ours is running it. Nothing is created.
  bool reveal(String sessionId) {
    final paneId = livePaneFor(sessionId);
    if (paneId == null) return false;
    _ref.read(terminalSessionsControllerProvider.notifier)
      ..reattachSession(paneId)
      ..focusPane(paneId);
    // The group that pane is in, not the focused one.
    _ref.read(terminalSessionsControllerProvider.notifier).revealPane(paneId);
    _ref.read(selectedSessionIdProvider.notifier).select(sessionId);
    // Where this session is on screen moved; nothing was created or renamed.
    _publish(SessionChange.moved(sessionId));
    return true;
  }

  // --- may a second process have it? -----------------------------------------

  /// Whether [agentId] permits a second process on a held conversation — the
  /// one read of [AgentLaunchSpec.allowsConcurrentResume]; unknown means false.
  bool allowsConcurrentResume(String agentId) =>
      _ref
          .read(agentRegistryProvider)
          .byId(agentId)
          ?.launch
          .allowsConcurrentResume ??
      false;

  /// What to show the user when we name the agent in a refusal.
  String agentDisplayName(String agentId) =>
      _ref.read(agentRegistryProvider).byId(agentId)?.displayName ?? agentId;

  /// **The** resume decision, for every surface. [canReattach] is false where
  /// reopening our own pane would not satisfy the request; nothing is inferred.
  ResumeAction resumeActionForConversation({
    required String agentId,
    String? sessionId,
    String? externalSessionId,
    bool canReattach = true,
    bool heldByAnotherProcess = false,
  }) => resumeActionFor(
    weHostItLive: hostedLive(
      sessionId: sessionId,
      externalSessionId: externalSessionId,
    ),
    allowsConcurrentResume: allowsConcurrentResume(agentId),
    heldByAnotherProcess: heldByAnotherProcess,
    canReattach: canReattach,
  );

  /// Whether **we** are running this conversation, by either name it has. Both
  /// are needed: a native Codex row often carries no CLI id at all.
  bool hostedLive({String? sessionId, String? externalSessionId}) =>
      livePaneFor(sessionId) != null ||
      heldByHostOnly(sessionId) ||
      runningSessionWithExternalId(externalSessionId) != null;

  /// Throws the plain-words refusal for a handoff the agent forbids. Shared, so
  /// the paths that cannot reattach cannot drift apart.
  void refuseIfForbidden({
    required String agentId,
    String? sessionId,
    String? externalSessionId,
    bool heldByAnotherProcess = false,
  }) {
    final action = resumeActionForConversation(
      agentId: agentId,
      sessionId: sessionId,
      externalSessionId: externalSessionId,
      canReattach: false,
      heldByAnotherProcess: heldByAnotherProcess,
    );
    if (action != ResumeAction.blocked) return;
    final running =
        runningSessionWithExternalId(externalSessionId) ??
        (livePaneFor(sessionId) == null && !heldByHostOnly(sessionId)
            ? null
            : _ref.read(sessionsDataProvider).getById(sessionId!));
    throw SessionAlreadyRunning(
      agentName: agentDisplayName(agentId),
      sessionId: running?.id,
      title: running?.title,
    );
  }

  /// The live terminal behind [sessionId], or null. Three things have to be
  /// true and each has been wrong on its own — see [livePaneFor].
  Terminal? _liveTerminalFor(String sessionId) {
    final paneId = livePaneFor(sessionId);
    if (paneId == null) return null;
    return _ref
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(paneId)
        ?.terminal;
  }
}

bool _isLive(PaneLiveness liveness) => liveness.isLive;

bool _isRestored(PaneLiveness liveness) => liveness == PaneLiveness.restored;
