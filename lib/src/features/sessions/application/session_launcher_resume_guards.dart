part of 'session_launcher.dart';

/// The three questions asked before a conversation is handed to a second
/// process, and the readings they are answered from.
///
/// *Is it already running?* — a pane of ours, live or merely restored, and the
/// row that holds the CLI's own id for it. *May a second process have it?* —
/// the agent's own answer, never a guess. *Was the conversation ever
/// written?* — the store, and only on certain knowledge.
///
/// Every surface that resumes anything comes through here, which is the point:
/// the refusal a user reads and the moment it is given must not be able to
/// drift apart per call site. An extension in a `part` for the reason
/// `session_launcher.dart` gives — these read `_ref` and publish through
/// `_publish`.
extension SessionResumeGuards on SessionLauncher {
  // --- is it already running? ------------------------------------------------

  /// The pane [sessionId] is running in **right now**, or `null`.
  ///
  /// Three things have to be true, and each of them has been wrong on its own:
  /// the row must exist, it must name a pane, and that pane's instance must say
  /// it is live. A detached pane is live (Loop 38); a pane restored from disk is
  /// not, whatever its buffer shows.
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
  /// Deliberately a second question rather than a loosening of [livePaneFor],
  /// because the two are asked for opposite reasons and both answers are
  /// load-bearing. A dormant pane is replayed history with nothing behind it,
  /// so it must never be reattached and presented as a running session — which
  /// is what [livePaneFor] gates, for the double-writer refusal, the archive
  /// guard and the permission chip. But it *is* a real pane holding this
  /// session's own scrollback, so resuming into it is what leaves the user one
  /// terminal for one session instead of a dead pane and a live one side by
  /// side.
  ///
  /// A pane whose process ran and exited is not dormant: it belongs to this run
  /// of the app, its buffer has moved on since anything was restored into it,
  /// and a resume gets a pane of its own. [PaneLiveness.restored] is the only
  /// state that says "rebuilt from disk, never started".
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
  /// [externalSessionId] in, or `null`.
  ///
  /// The external id is the join: an imported CLI entry and one of our rows are
  /// two records of the same conversation, and resuming the imported one while
  /// our own process holds it is exactly the double-writer case.
  ///
  /// **Every** row with that id is examined, not the first one the database
  /// hands back. `external_session_id` has no `UNIQUE` constraint and a resume
  /// used to mint a second row for a conversation that already had one, so a
  /// single-row read answered with whichever the engine felt like — and a dead
  /// duplicate answers "nothing is running this" while a pane is still writing
  /// to it. That is the answer this method exists to never give: it gates the
  /// refusal that keeps a second writer off a Codex thread.
  ///
  /// Newest-first (see `SessionDao.getAllByExternalSessionId`), so when an agent
  /// permits two live processes on one conversation the one just started is the
  /// one named.
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
  /// selects it. Returns false when nothing of ours is running it.
  ///
  /// This is what "resume" should do for a session that never stopped: a
  /// detached pane comes back as a tab, one already in a tab is focused, and
  /// nothing is created. The same three lines used to live inline in the MCP
  /// surface and nowhere else, which is why every other path relaunched.
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

  /// Whether [agentId] permits a second process on a conversation another one is
  /// already holding.
  ///
  /// The single read of [AgentLaunchSpec.allowsConcurrentResume] in the app, so
  /// "Claude can, Codex cannot" is answered from the registry rather than
  /// re-derived per call site. An agent we do not recognise answers `false`,
  /// which is the same safe default the field itself carries.
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
  /// satisfy the request. It is false for a handoff to a terminal window we do
  /// not own: there, a live pane of ours is just another process holding the
  /// conversation, and only the agent's capability decides.
  ///
  /// [heldByAnotherProcess] is for callers that have *certain* knowledge of a
  /// holder we do not own — an agent's own refusal, read off its screen (see
  /// `SessionWhereabouts.knownHeldElsewhere`). It is never inferred here.
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
  /// has: one of our session rows, or the CLI's own id.
  ///
  /// Both are needed and neither is enough. An imported entry only knows the CLI
  /// id; a native Codex row often has no CLI id at all, because Codex will not
  /// accept one and it is only discovered afterwards — so a check that used only
  /// the external id silently passed every native Codex session.
  bool hostedLive({String? sessionId, String? externalSessionId}) =>
      livePaneFor(sessionId) != null ||
      runningSessionWithExternalId(externalSessionId) != null;

  /// Throws the plain-words refusal for a handoff the agent forbids, or returns
  /// normally. Shared by the paths that cannot reattach so their message, and
  /// the moment they give up, cannot drift apart.
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
  /// read back from the agent rather than handed to it.
  ///
  /// The whole distinction this fix turns on, and it is readable straight off
  /// the data: `launch` assigns a new session *our own row id* as the CLI's
  /// session id (see `assignsOwnId`), so `sessions.id == external_session_id`
  /// is the signature of an id we promised rather than one we observed.
  ///
  /// An observed id — a hook payload, an imported store entry, a discovered
  /// Codex thread — is evidence the conversation existed, and is deliberately
  /// left alone here: the store is the only witness for it, and asking the
  /// store about a conversation the store already told us about would let a
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
  ///
  /// Also corrects the row on the way out. It said `running` from the moment it
  /// was written, which is the earliest anything *could* have said so and, for
  /// a conversation that was never written, was never true. This is the first
  /// moment the app knows better, so it is the moment to stop the row claiming
  /// otherwise.
  Future<void> refuseIfConversationMissing(SessionLaunchRequest request) async {
    final externalId = request.resumeExternalSessionId;
    if (externalId == null || externalId.isEmpty) return;
    final minted = rowThatMinted(externalId);
    if (minted == null || minted.isArchived) return;
    final descriptor = _ref
        .read(agentRegistryProvider)
        .byId(request.installation.agentId);
    // Expressed through the descriptor, never through an agent's name: an
    // agent that does not take an id from us cannot have made this promise,
    // and its store is asked about nothing.
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
  /// **This app moves sessions between directories on purpose**, which is why
  /// the question is asked at all:
  ///
  /// * `SessionArchiveService` removes a worktree and keeps the row, so
  ///   `directoryOrFallback` resumes from the repository root instead;
  /// * `SessionHandoffService.forkSession(intoNewWorktree: true)` launches
  ///   `--resume <source> --fork-session` in a worktree the source conversation
  ///   was never started in.
  ///
  /// (A third path was suspected and is not one: `select_checkout` moves the
  /// Explorer's selection through `CheckoutPicker` and never touches a
  /// session's working directory. `session_cwd_rule_test.dart` pins that.)
  ///
  /// A sentence and not a refusal, for the reason [resumeDirectoryCaveatFor]
  /// gives at length: the launch is still the best thing to do, and every other
  /// unknown in this area resolves the permissive way. It is also unreachable
  /// for the three agents shipped today, all of which declare
  /// [AgentResumeLocality.anyDirectory] against evidence.
  String? conversationElsewhereCaveat(
    SessionLaunchRequest request,
    EnvironmentPath launchDirectory,
  ) {
    final conversationId =
        request.resumeExternalSessionId ?? request.forkExternalSessionId;
    if (conversationId == null || conversationId.isEmpty) return null;
    // The row that *holds* this conversation, which for a fork is the source
    // session and not the one being created. Asked of the id rather than of
    // `reused`, because a fork has no reusable row at all.
    final holder = _ref
        .read(sessionDaoProvider)
        .getByExternalSessionId(conversationId);
    final recorded = holder?.workingDirectory ?? holder?.worktree;
    // A row that never recorded a directory (before schema v22) tells us
    // nothing about where the conversation was written, and an unknown earns
    // no sentence.
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
