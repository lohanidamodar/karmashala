part of 'session_launcher.dart';

/// Is it already running, may a second process have it, was it ever written —
/// asked here for every surface, so a refusal cannot drift apart per call site.
extension SessionResumeGuards on SessionLauncher {
  // --- is it already running? ------------------------------------------------

  /// The pane [sessionId] is running in **right now**, or `null`. A detached
  /// pane is live; one restored from disk is not, whatever its buffer shows.
  String? livePaneFor(String? sessionId) {
    if (sessionId == null) return null;
    final paneId = _ref.read(sessionDaoProvider).getById(sessionId)?.paneId;
    if (paneId == null) return null;
    final instance = _ref
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(paneId);
    return instance != null && instance.liveness.value.isLive ? paneId : null;
  }

  /// The pane [sessionId] was **restored** into and has never run, or `null`:
  /// it holds this session's own scrollback but nothing running behind it.
  String? dormantPaneFor(String? sessionId) {
    if (sessionId == null) return null;
    final paneId = _ref.read(sessionDaoProvider).getById(sessionId)?.paneId;
    if (paneId == null) return null;
    final instance = _ref
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(paneId);
    return instance?.liveness.value == PaneLiveness.restored ? paneId : null;
  }

  /// The session we are already running conversation [externalSessionId] in.
  /// **Every** row with that id: `external_session_id` has no `UNIQUE` index.
  Session? runningSessionWithExternalId(String? externalSessionId) {
    if (externalSessionId == null || externalSessionId.isEmpty) return null;
    for (final candidate
        in _ref
            .read(sessionDaoProvider)
            .getAllByExternalSessionId(externalSessionId)) {
      if (livePaneFor(candidate.id) != null) return candidate;
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
    _ref
        .read(terminalSessionsControllerProvider.notifier)
        .showTerminalForPane(paneId);
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
        (livePaneFor(sessionId) == null
            ? null
            : _ref.read(sessionDaoProvider).getById(sessionId!));
    throw SessionAlreadyRunning(
      agentName: agentDisplayName(agentId),
      sessionId: running?.id,
      title: running?.title,
    );
  }

  // --- was the conversation ever written? ------------------------------------

  /// The row that **minted** [externalSessionId], or `null` when the id came
  /// back from the agent: `sessions.id == external_session_id` is our promise.
  Session? rowThatMinted(String? externalSessionId) {
    if (externalSessionId == null || externalSessionId.isEmpty) return null;
    final row = _ref.read(sessionDaoProvider).getById(externalSessionId);
    return row != null && row.externalSessionId == externalSessionId
        ? row
        : null;
  }

  /// Throws [SessionConversationMissing] when the agent's store has read to the
  /// end without finding the conversation; "could not tell" returns normally.
  Future<void> refuseIfConversationMissing(SessionLaunchRequest request) async {
    final externalId = request.resumeExternalSessionId;
    if (externalId == null || externalId.isEmpty) return;
    final minted = rowThatMinted(externalId);
    if (minted == null || minted.isArchived) return;
    final descriptor = _ref
        .read(agentRegistryProvider)
        .byId(request.installation.agentId);
    // Expressed through the descriptor, never through an agent's name: an agent
    // that does not take an id from us cannot have made this promise.
    if (descriptor == null ||
        !descriptor.launch.sessionIdAssignment.isSupported) {
      return;
    }
    final presence = await _ref.read(conversationPresenceProvider)(
      descriptor: descriptor,
      // Where the agent would have written it: the directory the session runs
      // in decides which environment's store holds the transcript.
      environmentId:
          (minted.workingDirectory ??
                  minted.worktree ??
                  request.repository.path)
              .environmentId,
      conversationId: externalId,
    );
    if (presence != ConversationPresence.absent) return;
    _ref.read(sessionDaoProvider).updateStatus(minted.id, SessionStatus.failed);
    _publish(SessionChange.statusChanged(minted.id));
    throw SessionConversationMissing(
      agentName: agentDisplayName(request.installation.agentId),
      conversationId: externalId,
      sessionId: minted.id,
      title: minted.title,
    );
  }

  /// What to tell the user when [request] continues a conversation from another
  /// directory — unreachable while every agent declares [AgentResumeLocality].
  String? conversationElsewhereCaveat(
    SessionLaunchRequest request,
    EnvironmentPath launchDirectory,
  ) {
    final conversationId =
        request.resumeExternalSessionId ?? request.forkExternalSessionId;
    if (conversationId == null || conversationId.isEmpty) return null;
    // The row that *holds* this conversation — for a fork the source session,
    // not the one being created, which is why the id is asked and not `reused`.
    final holder = _ref
        .read(sessionDaoProvider)
        .getByExternalSessionId(conversationId);
    final recorded = holder?.workingDirectory ?? holder?.worktree;
    // A row that never recorded a directory (before schema v22) says nothing
    // about where the conversation was written, and an unknown earns no words.
    if (recorded == null) return null;
    return resumeDirectoryCaveatFor(
      _ref.read(agentRegistryProvider),
      request.installation.agentId,
      conversationId,
      recordedDirectory: recorded.path,
      launchDirectory: launchDirectory.path,
    );
  }

  /// The live terminal behind [sessionId], or null. Three things have to be
  /// true and each has been wrong on its own — see [livePaneFor].
  Terminal? _liveTerminalFor(String sessionId) {
    final paneId = _ref.read(sessionDaoProvider).getById(sessionId)?.paneId;
    if (paneId == null) return null;
    final instance = _ref
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(paneId);
    if (instance == null || !instance.liveness.value.isLive) return null;
    return instance.terminal;
  }
}
