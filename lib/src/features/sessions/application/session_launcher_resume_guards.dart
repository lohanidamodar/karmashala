part of 'session_launcher.dart';

/// The three questions asked before a conversation is handed to a second
/// process: is it already running, may a second process have it (the agent's
/// own answer, never a guess), and was the conversation ever written. Every
/// surface that resumes comes through here, so the refusal a user reads and the
/// moment it is given cannot drift apart per call site.
extension SessionResumeGuards on SessionLauncher {
  // --- is it already running? ------------------------------------------------

  /// The pane [sessionId] is running in **right now**, or `null`. Three things
  /// have to be true and each has been wrong on its own: the row exists, it
  /// names a pane, and that pane's instance is live. A detached pane is live; a
  /// pane restored from disk is not, whatever its buffer shows.
  String? livePaneFor(String? sessionId) {
    if (sessionId == null) return null;
    final paneId = _ref.read(sessionDaoProvider).getById(sessionId)?.paneId;
    if (paneId == null) return null;
    final instance = _ref
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(paneId);
    return instance != null && instance.liveness.value.isLive ? paneId : null;
  }

  /// The pane [sessionId] was **restored** into and has never run, or `null`.
  ///
  /// A second question rather than a loosening of [livePaneFor]: a dormant pane
  /// is replayed history with nothing behind it, so it must never be reattached
  /// and presented as a running session — but it does hold this session's own
  /// scrollback, so resuming into it leaves one terminal per session. A pane
  /// whose process ran and exited is not dormant; [PaneLiveness.restored] is
  /// the only state that says "rebuilt from disk, never started".
  String? dormantPaneFor(String? sessionId) {
    if (sessionId == null) return null;
    final paneId = _ref.read(sessionDaoProvider).getById(sessionId)?.paneId;
    if (paneId == null) return null;
    final instance = _ref
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(paneId);
    return instance?.liveness.value == PaneLiveness.restored ? paneId : null;
  }

  /// The session we are already running the CLI conversation
  /// [externalSessionId] in, or `null` — the external id is the join between an
  /// imported CLI entry and one of our own rows.
  ///
  /// **Every** row with that id is examined: `external_session_id` has no
  /// `UNIQUE` constraint, and a dead duplicate would answer "nothing is running
  /// this" while a pane is still writing to it. Newest-first, so where an agent
  /// permits two live processes the one just started is the one named.
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

  /// Brings the pane [sessionId] is already running in back into view and
  /// selects it; false when nothing of ours is running it. This is what
  /// "resume" should do for a session that never stopped — nothing is created.
  bool reveal(String sessionId) {
    final paneId = livePaneFor(sessionId);
    if (paneId == null) return false;
    _ref.read(terminalSessionsControllerProvider.notifier)
      ..reattachSession(paneId)
      ..focusPane(paneId);
    // The group that pane is in, not the focused one.
    _ref.read(terminalSessionsControllerProvider.notifier).showTerminalForPane(paneId);
    _ref.read(selectedSessionIdProvider.notifier).select(sessionId);
    // Where this session is on screen moved; nothing was created or renamed.
    _publish(SessionChange.moved(sessionId));
    return true;
  }

  // --- may a second process have it? -----------------------------------------

  /// Whether [agentId] permits a second process on a conversation another one
  /// is already holding — the single read of
  /// [AgentLaunchSpec.allowsConcurrentResume] in the app, so "Claude can, Codex
  /// cannot" is answered from the registry. An unrecognised agent answers
  /// `false`.
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

  /// **The** resume decision, for every surface.
  ///
  /// [canReattach] is the caller saying whether reopening our own pane would
  /// satisfy the request — false for a handoff to a terminal window we do not
  /// own, where only the agent's capability decides. [heldByAnotherProcess] is
  /// for callers with *certain* knowledge of a holder we do not own; it is
  /// never inferred here.
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

  /// Whether **we** are running this conversation right now, by either name it
  /// has: one of our rows, or the CLI's own id. Both are needed — an imported
  /// entry only knows the CLI id, and a native Codex row often has none at all,
  /// so a check on the external id alone silently passed every Codex session.
  bool hostedLive({String? sessionId, String? externalSessionId}) =>
      livePaneFor(sessionId) != null ||
      runningSessionWithExternalId(externalSessionId) != null;

  /// Throws the plain-words refusal for a handoff the agent forbids, or returns
  /// normally. Shared by the paths that cannot reattach, so their message and
  /// the moment they give up cannot drift apart.
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

  /// The row that **minted** [externalSessionId], or `null` when that id was
  /// read back from the agent rather than handed to it: `launch` gives a new
  /// session its own row id as the CLI's session id, so `sessions.id ==
  /// external_session_id` is the signature of an id we promised. An observed id
  /// is deliberately left alone — the store is its only witness, and asking the
  /// store about a conversation it already told us about would let a
  /// misconfigured `CLAUDE_CONFIG_DIR` retract a fact we had.
  Session? rowThatMinted(String? externalSessionId) {
    if (externalSessionId == null || externalSessionId.isEmpty) return null;
    final row = _ref.read(sessionDaoProvider).getById(externalSessionId);
    return row != null && row.externalSessionId == externalSessionId
        ? row
        : null;
  }

  /// Throws [SessionConversationMissing] when [request] would resume a
  /// conversation the agent's store has read to the end without finding, and
  /// returns normally in every other case — including "we could not tell".
  /// Corrects the row on the way out: it has claimed `running` since it was
  /// written, and this is the first moment the app knows better.
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

  /// What to tell the user when [request] continues or forks a conversation
  /// from a directory it was not recorded in, or `null` when there is nothing
  /// to say.
  ///
  /// This app moves sessions between directories on purpose — an archived
  /// worktree resumes from the repository root, and a fork into a new worktree
  /// launches `--resume … --fork-session` where the source never ran. A
  /// sentence and not a refusal: the launch is still the best thing to do. It
  /// is also unreachable for the three agents shipped today, all of which
  /// declare [AgentResumeLocality.anyDirectory] against evidence.
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
    // about where the conversation was written, and an unknown earns no
    // sentence.
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
