part of 'session_launcher.dart';

/// Is it already running, may a second process have it, was it ever written —
/// asked here for every surface, so a refusal cannot drift apart per call site.
extension SessionResumeGuards on SessionLauncher {
  // --- is it already running? ------------------------------------------------

  /// The pane [sessionId] is running in **right now**, or `null`. A detached
  /// pane is live; one restored from disk is not, whatever its buffer shows.
  String? livePaneFor(String? sessionId) {
    if (sessionId == null) return null;
    final paneId = _ref.read(sessionsDataProvider).getById(sessionId)?.paneId;
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
    final paneId = _ref.read(sessionsDataProvider).getById(sessionId)?.paneId;
    if (paneId == null) return null;
    final instance = _ref
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(paneId);
    return instance?.liveness.value == PaneLiveness.restored ? paneId : null;
  }

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

  // --- was the conversation ever written? ------------------------------------

  /// The row that **minted** [externalSessionId], or `null` when the id came
  /// back from the agent: `sessions.id == external_session_id` is our promise.
  Session? rowThatMinted(String? externalSessionId) {
    if (externalSessionId == null || externalSessionId.isEmpty) return null;
    final row = _ref.read(sessionsDataProvider).getById(externalSessionId);
    return row != null && row.externalSessionId == externalSessionId
        ? row
        : null;
  }

  /// [request] with the conversation it can actually resume. A row pointed at a
  /// conversation its agent never wrote goes back to the one named after it —
  /// its own, from launch — and the row is repaired. Throws
  /// [SessionConversationMissing] when the store was read to the end and holds
  /// neither; "could not tell" returns [request] unchanged.
  Future<SessionLaunchRequest> conversationToResume(
    SessionLaunchRequest request,
  ) async {
    final externalId = request.resumeExternalSessionId;
    if (externalId == null || externalId.isEmpty) return request;
    final descriptor = _ref
        .read(agentRegistryProvider)
        .byId(request.installation.agentId);
    // Expressed through the descriptor, never through an agent's name: only an
    // agent that takes an id from us has a row id to fall back to, and its
    // store is one whose "absent" is read to the end (not Codex's archive).
    if (descriptor == null ||
        !descriptor.launch.sessionIdAssignment.isSupported) {
      return request;
    }
    final minted = rowThatMinted(externalId);
    final row = minted ?? _reusableRowForResume(request);
    if (row == null || row.isArchived) return request;
    // Where the agent would have written it: the directory the session runs
    // in decides which environment's store holds the transcript.
    final environmentId =
        (row.workingDirectory ?? row.worktree ?? request.repository.path)
            .environmentId;
    Future<ConversationPresence> presenceOf(String id) => _ref.read(
      conversationPresenceProvider,
    )(descriptor: descriptor, environmentId: environmentId, conversationId: id);
    if (await presenceOf(externalId) != ConversationPresence.absent) {
      return request;
    }
    final dao = _ref.read(sessionsDataProvider);
    if (minted == null) {
      final holder = dao.getByExternalSessionId(row.id);
      if ((holder == null || holder.id == row.id) &&
          await presenceOf(row.id) == ConversationPresence.present) {
        refuseIfForbidden(
          agentId: request.installation.agentId,
          externalSessionId: row.id,
        );
        dao.updateExternalSessionId(row.id, row.id);
        _log.warning(
          'Session ${row.id} named conversation $externalId, which '
          '${descriptor.displayName} has no record of; resuming its own '
          'conversation ${row.id} instead and repairing the row.',
        );
        return request.withResumeExternalSessionId(row.id);
      }
      _log.warning(
        'Session ${row.id} names conversation $externalId, which '
        '${descriptor.displayName} has no record of, and its own conversation '
        'is not in the store either; not launching.',
      );
      throw SessionConversationMissing(
        agentName: agentDisplayName(request.installation.agentId),
        conversationId: externalId,
        sessionId: row.id,
        title: row.title,
        pointedElsewhere: true,
      );
    }
    // Not for a row the host knows: a conversation not written *yet* — its
    // agent still at a first-run question, say — is no failed session.
    if (_mayRecordLaunchFailure(minted)) {
      dao.updateStatus(minted.id, SessionStatus.failed);
      _publish(SessionChange.statusChanged(minted.id));
    }
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
        .read(sessionsDataProvider)
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
    final paneId = _ref.read(sessionsDataProvider).getById(sessionId)?.paneId;
    if (paneId == null) return null;
    final instance = _ref
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(paneId);
    if (instance == null || !instance.liveness.value.isLive) return null;
    return instance.terminal;
  }
}
