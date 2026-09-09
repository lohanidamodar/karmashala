part of 'session_launcher.dart';

/// **The** way a session comes into existence, and the way one is
/// re-created on the same conversation.
///
/// An extension in a `part` rather than a library of its own, for the reason
/// every split of this class runs into: privacy in Dart is per library, and
/// every verb here reads the launcher's own `_ref` and calls the private
/// surface starters beside it. See `session_launcher.dart` for the rule the
/// whole file is built to — the row, the mode and the directory are decided
/// here and nowhere else.
extension SessionStartVerbs on SessionLauncher {
  /// Ends the agent [sessionId] is running now and starts a new one on the same
  /// conversation — the only way a mode written by [setPermissionMode] can
  /// reach a session that is already up.
  ///
  /// This does not contradict the reasoning above; it is the other half of it.
  /// Nothing here talks to the live process about its policy. The process is
  /// *replaced* by one whose command line carries the new flags, and the
  /// conversation is carried across by the agent's own resume convention, so
  /// the user keeps the transcript and loses only the turn that was in flight.
  ///
  /// **Every refusal happens before anything is killed.** A row that has gone,
  /// a conversation the CLI has never named, a repository or an installation no
  /// longer in the workspace — each is checked while the agent is still
  /// running, so a restart that cannot happen costs the user nothing. Ordered
  /// the other way, the same conditions would end working sessions and then
  /// explain why they could not be restarted.
  ///
  /// The conversation id is the load-bearing one. Without it the relaunch has
  /// nothing to hand the resume convention, so the agent would come up on a
  /// *new* conversation wearing this session's row, title and history — the
  /// silent loss [SessionConversationMissing] guards against from the other
  /// direction. A Codex session spends its first moments in exactly that state,
  /// because Codex will not accept an id from us and one is only discovered
  /// afterwards, so this is an ordinary condition and not a corrupt row.
  ///
  /// The pane does not survive, and cannot: a pane will not take a second
  /// process while the first is still in it (see
  /// [TerminalSessionsController.startAgentInPane], which refuses a live pane)
  /// and there is no way to stop that process without disposing the terminal
  /// showing it. What the user is continuing is the agent's transcript rather
  /// than this run's scrollback, and `--resume` is what brings that back —
  /// including into the chat view, which is built from the agent's own store
  /// and never from the buffer.
  ///
  /// Note what is deliberately *not* passed to [launch]. No permission
  /// override: the mode is on the row by the time this is called and [launch]
  /// reads it from there, whereas an override would also be written back, which
  /// is precisely what freezes a session that is deliberately following the
  /// Settings default. No working directory either: the row already carries it,
  /// and restating it here would be a second answer able to disagree with the
  /// one every other resume gets.
  Future<SessionLaunchResult> restartSession(String sessionId) async {
    final session = _ref.read(sessionDaoProvider).getById(sessionId);
    if (session == null) {
      throw StateError('This session no longer exists.');
    }
    final installation = _ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId);
    if (installation == null) {
      throw StateError(
        'The agent for this session is not installed. '
        'Run "Discover agents" in Settings.',
      );
    }
    final repository = _ref
        .read(repositoryDaoProvider)
        .getById(session.repositoryId);
    if (repository == null) {
      throw StateError('The session\'s repository is no longer available.');
    }
    final externalId = session.externalSessionId;
    if (externalId == null || externalId.isEmpty) {
      throw StateError(
        '${agentDisplayName(installation.agentId)} has not named a '
        'conversation for this session yet, so restarting it would open a new '
        'conversation instead of continuing this one.',
      );
    }

    // Only now, once nothing above can refuse. Ending is not undoable: the
    // agent is asked to exit and killed if it will not, and whatever it was in
    // the middle of goes with it.
    //
    // A session with no live pane is not an error here — it is a session that
    // already stopped, and starting it again is exactly what was asked for.
    final paneId = livePaneFor(sessionId);
    if (paneId != null) {
      _ref.read(terminalSessionsControllerProvider.notifier).endSession(paneId);
    }
    // After the kill, not before it, so the line records an agent that is
    // actually gone rather than one we were about to end — and gone is the
    // fact a user asking "where did my agent go" needs, whether or not the
    // launch below succeeds. [launch] logs the process that replaced it.
    _log.info(
      'Restarting $sessionId to apply its permission mode: '
      'agent=${installation.agentId} ended=${paneId ?? 'nothing'} '
      'conversation=$externalId',
    );

    return launch(
      SessionLaunchRequest(
        repository: repository,
        installation: installation,
        title: session.title,
        purpose: SessionPurpose.existingSession,
        resumeExternalSessionId: externalId,
        // So [_reusableRowForResume] continues *this* row instead of minting a
        // second one beside it: it compares the request's surface against the
        // candidate's, and a mismatch is one of the ways a single conversation
        // ended up with two rows before Loop 66.
        surface: session.surface,
      ),
    );
  }

  /// The body of [SessionLauncher.launch], which stays on the class.
  ///
  /// The one member of this file that could not move under its own name.
  /// `launch` is the seam two test doubles replace by subclassing the
  /// launcher, and an extension member cannot be overridden — a subclass
  /// declaring one would be ignored at every call site, silently — so the
  /// class keeps a four-line `launch` that calls this.
  Future<SessionLaunchResult> _launch(SessionLaunchRequest request) async {
    // First, and before anything is *asked* as well as before anything is
    // written: a restart is the statement that there is no conversation to
    // continue, so carrying a resume or a fork alongside it asks for one
    // conversation to be continued and replaced at once. Refused on the shape
    // of the request alone — a request that makes no sense must not need a
    // store read to be turned down, and the reuse below silently prefers the
    // resume, so falling through would hand the user the other thing.
    if (request.restartSessionId != null &&
        (request.resumeExternalSessionId != null ||
            request.forkExternalSessionId != null)) {
      throw ArgumentError(
        'A launch cannot restart a session and also resume or fork a '
        'conversation.',
      );
    }

    // Before anything is written: a resume of a conversation we are still
    // running would be a second agent on it. Callers that can reopen the running
    // view do so and never get here; this is the backstop for the ones that
    // cannot, and for whatever is added next.
    //
    // It asks the agent rather than refusing outright. Launching is a *create*,
    // so it can never reattach — but for an agent that permits concurrent
    // resume (Claude Code) a second process is exactly what was asked for, and
    // blocking it here refused the one case the user wanted to keep.
    refuseIfForbidden(
      agentId: request.installation.agentId,
      externalSessionId: request.resumeExternalSessionId,
    );

    // And a resume of a conversation the agent never wrote is not a resume at
    // all. Asked here, before anything is written, for the same reason as the
    // refusal above: every surface that continues a session comes through this
    // method, and none of them should have to remember.
    await refuseIfConversationMissing(request);

    // A request cannot both continue and branch one conversation: the two
    // produce different command lines (a resume convention vs a fork one) and
    // honouring either silently would give the user the other thing.
    if (request.resumeExternalSessionId != null &&
        request.forkExternalSessionId != null) {
      throw ArgumentError(
        'A launch cannot both resume and fork a conversation.',
      );
    }

    final depth = depthForChildOf(request.parentSessionId);
    if (!depth.isAllowed) throw SessionDepthRefused(depth);

    final descriptor = _ref
        .read(agentRegistryProvider)
        .byId(request.installation.agentId);
    // A first message an agent cannot be handed is a refusal, not a launch.
    //
    // `agentPaneArguments` drops the prompt when the CLI takes none, and every
    // caller above then reports success: fan-out records the candidate as
    // `started`, and the MCP `spawn` tool answers "opened a new session", so a
    // model believes its instruction landed when the agent came up bare. This
    // was unreachable while Antigravity was discovered under a name nothing
    // installs; correcting that name made it live. Refusing here closes
    // fan-out and MCP together, which is why it is not a guard at either.
    final message = request.firstMessage?.trim();
    if (message != null &&
        message.isNotEmpty &&
        !(descriptor?.launch.acceptsPromptArgument ?? false)) {
      throw SessionLaunchRefused(
        '${descriptor?.displayName ?? request.installation.agentId} takes no '
        'opening message on its command line, so this one would be dropped '
        'without a word. Start it and say it in the session instead.',
      );
    }

    // A resume continues a conversation we may already have a row for. Until
    // Loop 66 it minted a second one every time, so resuming a stopped session
    // left the dead row *and* a new one, both drawn in the tree and both
    // answering to the same CLI id — which is what made the double-writer check
    // above have to choose between rows at all. Reusing is what the imported
    // path has always done by deleting its own record afterwards; the native
    // path had no equivalent.
    //
    // Resolved *before* the permission mode, and that order is the fix for the
    // owner's report — "existing session permission mode should be overridable
    // in each session. but settings is taking precedence". This method used to
    // resolve the mode from the setting alone and then write it over the row it
    // was about to reuse, so every resume silently discarded the mode chosen on
    // the composer chip.
    // Or the row a restart is re-promising. The two are mutually exclusive by
    // the guard above, so this is an `??` and not a precedence decision.
    final reused =
        _reusableRowForResume(request) ?? _reusableRowForRestart(request);

    // What was **decided** for this session, in priority order: a caller that
    // resolved one for this launch (a handoff's carry, a review's cap, an MCP
    // request that named a mode), otherwise the row's own choice. Null means
    // nobody ever chose, and the setting answers — live, so changing it moves
    // this session and every other that never chose.
    final chosenMode =
        request.permissionOverride?.canonical ?? reused?.permissionMode;
    final permissionMode = permissionFor(
      request.installation.agentId,
      request.purpose,
      sessionMode: chosenMode,
    );

    // The same shape one line down, and the same rule: a caller's decision, or
    // the row's own, or — resolved live — the per-agent default. Null all the
    // way down means no model flag at all, which is what every session did
    // before there was a model chip and is still the honest answer.
    final modelId = resolveSessionModel(
      sessionModelId: request.modelOverride ?? reused?.modelId,
      defaultModelId: defaultModelFor(request.installation.agentId),
    ).modelId;

    final id = reused?.id ?? _ref.read(idGeneratorProvider).newId();

    if (request.useWorktree && request.existingWorktree != null) {
      throw ArgumentError(
        'A launch cannot both create a worktree and join an existing one.',
      );
    }

    var workingDirectory = request.repository.path;
    // What to write on the row, which is the launch directory except when we
    // fell back off a directory that has gone away — see below.
    var recordDirectory = true;
    String? workingDirectoryNotice;
    EnvironmentPath? worktree;
    if (request.existingWorktree != null) {
      // Joining, not creating. A handoff and a same-worktree fork continue the
      // work *where it is*, on the branch it is on, so the receiving agent sees
      // the tree the recap describes rather than a clean checkout of the
      // repository root.
      workingDirectory = request.existingWorktree!;
      worktree = request.existingWorktree;
    } else if (request.useWorktree) {
      final created = await _ref
          .read(worktreeServiceProvider)
          .createForSession(
            repo: request.repository.path,
            worktreeName: sessionWorktreeName(id),
            branch: sessionBranchName(id),
          );
      workingDirectory = created.path;
      worktree = created.path;
    } else {
      // Where this conversation was actually running, from the caller when it
      // knows (a handoff, a fork) and otherwise from the row being resumed —
      // which is what makes a resume from the Explorer land in an adopted
      // session's own subdirectory without the Explorer having to say so.
      final resolved = directoryOrFallback(
        _ref,
        // The row's worktree is the same fact for a row written before schema
        // v22, which recorded no directory but did record where it ran. It is
        // read here and not turned into `worktree`: the reused row already
        // carries that, and a launch must not invent one.
        directory:
            request.workingDirectory ??
            reused?.workingDirectory ??
            reused?.worktree,
        fallback: request.repository.path,
      );
      workingDirectory = resolved.directory;
      // Falling back rather than failing: a resume must still happen. The
      // record is kept when we fell back, because a missing folder is often
      // temporary — an unmounted drive, a WSL distro that is not running — and
      // forgetting it would turn that into permanent data loss.
      workingDirectoryNotice = resolved.notice;
      recordDirectory = resolved.notice == null;
    }

    // Asked last, because it is the first thing that can only be answered once
    // the directory is known: is this launch continuing or forking a
    // conversation from somewhere other than where it was recorded, on an agent
    // nobody has verified can find it from there? Joined onto whatever the
    // fallback above already had to say, because both sentences are about the
    // same substitution and the user reads one line.
    workingDirectoryNotice = [
      ?workingDirectoryNotice,
      ?conversationElsewhereCaveat(request, workingDirectory),
    ].join(' ');
    if (workingDirectoryNotice.isEmpty) workingDirectoryNotice = null;

    // A resumed session already has a CLI id. A new one gets *ours* when the
    // agent will accept it — our ids are RFC-4122 v4, which is what
    // `--session-id` wants — so the transcript that backs the chat view is
    // locatable at launch instead of guessed at afterwards. Agents that cannot
    // be told (Codex) keep a null id until something discovers it.
    //
    // A **fork** is a create, not a resume: the CLI is told to start a new
    // conversation seeded from an old one, so it will mint its own id — which
    // is the entire meaning of Claude's `--fork-session`, "create a new session
    // ID instead of reusing the original". So the fork's source id is never
    // recorded as this session's own, and we do not offer ours either: passing
    // `--session-id` alongside `--fork-session` would ask the CLI for a new id
    // and then name the one it must not reuse.
    final assignsOwnId =
        request.resumeExternalSessionId == null &&
        request.forkExternalSessionId == null &&
        (descriptor?.launch.sessionIdAssignment.isSupported ?? false);
    final externalSessionId =
        request.resumeExternalSessionId ?? (assignsOwnId ? id : null);

    // A session an agent asked for names its parent in the prompt, because the
    // prompt is the only channel the spawned agent has. Built from the parent's
    // own row, and stripped again by rebuilding the same string — never by
    // pattern-matching the text. See [SessionAttribution].
    final attribution = attributionFor(request.parentSessionId);
    final firstMessage = attribution == null || request.firstMessage == null
        ? request.firstMessage
        : attribution.render(request.firstMessage!);

    // Reusing keeps the row's own identity — title, creation time, lineage,
    // worktree — and changes only what a resume actually changes. Rebuilding it
    // from the request would let "continue this session" quietly rename it (the
    // imported path passes the CLI's title) or re-date it.
    final session =
        reused?.copyWith(
          status: SessionStatus.running,
          // `copyWith` keeps the row's own mode when this is null, which is
          // the point: a resume must not overwrite a choice, and must not
          // freeze a session that never made one.
          permissionMode: request.permissionOverride?.canonical,
          modelId: request.modelOverride,
          workingDirectory: recordDirectory ? workingDirectory : null,
        ) ??
        Session(
          id: id,
          repositoryId: request.repository.id,
          agentInstallationId: request.installation.id,
          title: request.title.trim().isEmpty
              ? 'Session'
              : request.title.trim(),
          // True for a joined worktree as well as a created one: the row says
          // where this session runs, and it does run in a worktree.
          useWorktree: request.useWorktree || worktree != null,
          worktree: worktree,
          // The directory the process is about to be started in — a fact, and
          // the same one an adopted session records. Two sources for it would
          // drift.
          workingDirectory: recordDirectory ? workingDirectory : null,
          status: SessionStatus.running,
          createdAt: _ref.read(clockProvider).nowUtc(),
          externalSessionId: externalSessionId,
          parentSessionId: request.parentSessionId,
          // A parent with no stated reason is a spawn — the only way a session
          // could acquire one before schema v13, and what the MCP path still means
          // when it names a caller without saying more.
          parentLink: request.parentSessionId == null
              ? null
              : (request.parentLink ?? SessionLink.spawn),
          surface: request.surface,
          view: request.view ?? defaultViewFor(descriptor),
          // Only what was **chosen**, which for an ordinary launch is nothing.
          // Stamping the resolved default here read as a per-session decision
          // afterwards, so every session was frozen at whatever Settings
          // happened to say on the day it started and changing the default
          // moved nothing — the opposite half of the owner's report. The
          // effective mode is not lost by leaving this null: it is
          // [resolveSessionPermission] of this row and the live setting, which
          // is the same answer the chip and the next launch compute.
          permissionMode: request.permissionOverride?.canonical,
          // Only what was **chosen**, for the reason above: a launch that
          // stamped the resolved model here would freeze this session on
          // whichever model Settings named today.
          modelId: request.modelOverride,
        );
    final dao = _ref.read(sessionDaoProvider);
    if (reused == null) {
      dao.insert(session);
    } else {
      dao.updateStatus(id, SessionStatus.running);
      // Written only when this launch carries a decision. Writing the resolved
      // mode unconditionally is what destroyed the chip's choice on the next
      // resume, and it would also stamp a default onto a session that is
      // deliberately following one.
      if (request.permissionOverride != null) {
        dao.updatePermissionMode(id, request.permissionOverride!.canonical);
      }
      if (request.modelOverride != null) {
        dao.updateModel(id, request.modelOverride);
      }
      if (recordDirectory) dao.updateWorkingDirectory(id, workingDirectory);
    }
    final repositoryDao = _ref.read(sessionRepositoryDaoProvider)
      ..link(id, request.repository.id, role: SessionRepositoryRole.primary);
    for (final extra in request.additionalRepositories) {
      repositoryDao.link(id, extra.id);
    }

    // The packet's way in that is not a paste, resolved here because the file
    // is named by the session it belongs to and [id] is minted above. Every
    // "no" falls back to the opening prompt, which is what carried the packet
    // before this existed — a session that opens without its brief in the
    // stronger channel is a smaller loss than one that does not open.
    final systemPromptFilePath = await _systemPromptFileFor(
      sessionId: id,
      request: request,
      descriptor: descriptor,
      directory: workingDirectory,
    );

    try {
      final result = switch (request.surface) {
        SessionSurface.pane => _startInPane(
          session,
          request,
          descriptor,
          permissionMode,
          modelId,
          workingDirectory,
          assignsOwnId,
          firstMessage,
          systemPromptFilePath,
          workingDirectoryNotice,
        ),
        SessionSurface.external => await _startInExternalTerminal(
          session,
          request,
          descriptor,
          permissionMode,
          modelId,
          workingDirectory,
          assignsOwnId,
          firstMessage,
          systemPromptFilePath,
          workingDirectoryNotice,
        ),
      };
      _publish(_whatALaunchMoved(request, id, reused: reused != null));
      return result;
    } catch (_) {
      // The row must not outlive a launch that never happened — that is exactly
      // the "session created as a side effect nothing observes" the audit found,
      // wearing the opposite hat.
      dao.updateStatus(id, SessionStatus.failed);
      // The same word as the success path: the row still appeared, and it is
      // still this one row that moved. A failed launch must reach every list
      // that draws it, and nothing else.
      _publish(_whatALaunchMoved(request, id, reused: reused != null));
      rethrow;
    }
  }

  /// What a launch actually moved, named rather than shouted.
  ///
  /// This used to be a bare `bump()` — [SessionChange.everything], the word for
  /// a caller that cannot say what changed. A launch can: one row appeared,
  /// started, and claimed a pane. The difference is the whole of the owner's
  /// *"starting new session is heavy and laggy too"*, because the coarse word
  /// raises `SessionSignals.broadcasts`, which is the floor under **every**
  /// per-row watcher — and the Explorer builds one
  /// [sessionWhereaboutsProvider] per drawn card. So creating one session
  /// re-read every session's row and re-scanned the screen of every dead pane,
  /// synchronously, on the UI isolate, inside the frame:
  /// `session_start_cost_test.dart` measured 158 statements, 35 screen scans
  /// and 39 rebuilds at a hundred sessions against 26, 2 and 6 at one.
  ///
  /// Naming the row leaves `broadcasts` alone, so the ninety-nine cards that
  /// did not change stay asleep. Every kind that any watcher of the *list*
  /// reads is still published, which is what keeps the new row appearing
  /// everywhere it must — see the second half of that test.
  SessionChange _whatALaunchMoved(
    SessionLaunchRequest request,
    String id, {
    required bool reused,
  }) => SessionChange(
    sessionId: id,
    kinds: {
      // A create grows the list. A resume reuses a row already in it — but
      // every watcher of the list watches membership anyway, so this is the
      // only kind the two cases differ on.
      if (!reused) SessionChangeKind.membership,
      SessionChangeKind.status,
      // The row claimed a pane, and a new session was just given its
      // conversation id — which is what hides the imported record for it.
      SessionChangeKind.placement,
      // Only a launch that carried a decision wrote a per-session policy.
      if (request.permissionOverride != null || request.modelOverride != null)
        SessionChangeKind.settings,
      // A created worktree is a checkout the picker has to start offering,
      // and the picker watches nothing else.
      if (request.useWorktree) SessionChangeKind.workspace,
    },
  );

  /// The row [request] should continue rather than duplicate, or `null` when
  /// this launch genuinely creates a session.
  ///
  /// Narrow on purpose — every condition below is a case where two rows is the
  /// honest answer:
  ///
  /// * **Not a resume.** A create is a create; a fork is a create too (the CLI
  ///   mints a new conversation id, so it cannot collide with an existing row).
  /// * **A new worktree.** The row records *where* a session runs, so moving the
  ///   conversation into a fresh checkout earns its own row.
  /// * **A stated parent.** A parented launch is asserting a new relationship,
  ///   and reuse would silently drop it.
  /// * **A live candidate.** `refuseIfForbidden` has already let this through,
  ///   which for an agent that permits concurrent resume means a second process
  ///   on the conversation was the point. That is a second session, not a
  ///   re-entry into the first — and overwriting a live row's pane id would lose
  ///   the process we are still holding.
  /// * **A different repository, installation or surface.** Same conversation,
  ///   different thing being run; the row would stop describing its own session.
  /// * **Archived.** Its worktree is gone; reviving it would point a live agent
  ///   at a directory that no longer exists.
  Session? _reusableRowForResume(SessionLaunchRequest request) {
    final externalId = request.resumeExternalSessionId;
    if (externalId == null || externalId.isEmpty) return null;
    if (request.useWorktree || request.parentSessionId != null) return null;
    for (final candidate
        in _ref
            .read(sessionDaoProvider)
            .getAllByExternalSessionId(externalId)) {
      if (candidate.isArchived) continue;
      if (candidate.repositoryId != request.repository.id) continue;
      if (candidate.agentInstallationId != request.installation.id) continue;
      if (candidate.surface != request.surface) continue;
      if (livePaneFor(candidate.id) != null) continue;
      return candidate;
    }
    return null;
  }

  /// The row a [SessionLaunchRequest.restartSessionId] launch continues *as*.
  ///
  /// Every guard [_reusableRowForResume] applies, for the same reasons, plus
  /// one this half needs and that one cannot express: the row is named
  /// directly rather than found by conversation id, because a restart's whole
  /// premise is that no conversation exists to look it up by.
  ///
  /// Reusing rather than inserting is what makes this different from the advice
  /// it replaces. `assignsOwnId` stays true — no resume, no fork — so the
  /// launch stamps the row's own id as the conversation id again, which is the
  /// same promise the row already carries. Nothing has to rewrite it.
  Session? _reusableRowForRestart(SessionLaunchRequest request) {
    final rowId = request.restartSessionId;
    if (rowId == null || rowId.isEmpty) return null;
    if (request.useWorktree || request.parentSessionId != null) return null;
    final candidate = _ref.read(sessionDaoProvider).getById(rowId);
    if (candidate == null || candidate.isArchived) return null;
    if (candidate.repositoryId != request.repository.id) return null;
    if (candidate.agentInstallationId != request.installation.id) return null;
    if (candidate.surface != request.surface) return null;
    // A pane of ours is running it, so there is a conversation after all and
    // starting a second one over this row would abandon the live one.
    if (livePaneFor(candidate.id) != null) return null;
    return candidate;
  }
}
