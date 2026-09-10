part of 'session_launcher.dart';

/// **The** way a session comes into existence, and the way one is re-created on
/// the same conversation. A `part` rather than its own library because privacy
/// in Dart is per library and every verb here reads the launcher's own `_ref`.
extension SessionStartVerbs on SessionLauncher {
  /// Ends the agent [sessionId] is running and starts a new one on the same
  /// conversation — the only way a mode written by [setPermissionMode] reaches
  /// a live session. Every refusal happens before anything is killed, and a
  /// session the CLI has not yet named a conversation for is one of them: the
  /// relaunch would come up on a *new* conversation wearing this row. Passes no
  /// override to [launch] — an override is also written back, which would
  /// freeze a session that is deliberately following the Settings default.
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

    // Only now, once nothing above can refuse: ending is not undoable. No live
    // pane is not an error — that session had already stopped.
    final paneId = livePaneFor(sessionId);
    if (paneId != null) {
      _ref.read(terminalSessionsControllerProvider.notifier).endSession(paneId);
    }
    // After the kill, so the line records an agent that is actually gone;
    // [launch] logs the process that replaced it.
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
        // second one: it compares the request's surface against the
        // candidate's.
        surface: session.surface,
      ),
    );
  }

  /// The body of [SessionLauncher.launch], which stays on the class: `launch`
  /// is the seam two test doubles replace by subclassing, and an extension
  /// member cannot be overridden — a subclass declaring one is ignored,
  /// silently.
  Future<SessionLaunchResult> _launch(SessionLaunchRequest request) async {
    // Refused on the shape of the request alone, before any store read: a
    // restart says there is no conversation to continue, and the reuse below
    // silently prefers the resume, so falling through would hand the user the
    // other thing.
    if (request.restartSessionId != null &&
        (request.resumeExternalSessionId != null ||
            request.forkExternalSessionId != null)) {
      throw ArgumentError(
        'A launch cannot restart a session and also resume or fork a '
        'conversation.',
      );
    }

    // Before anything is written: a resume of a conversation we are still
    // running would be a second agent on it. It asks the agent rather than
    // refusing outright — for one that permits concurrent resume (Claude Code)
    // a second process is exactly what was asked for.
    refuseIfForbidden(
      agentId: request.installation.agentId,
      externalSessionId: request.resumeExternalSessionId,
    );

    // Every surface that continues a session comes through here, so none of
    // them has to remember to ask.
    await refuseIfConversationMissing(request);

    // Resume and fork produce different command lines, so honouring either
    // silently would give the user the other thing.
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
    // A first message an agent cannot be handed is a refusal, not a launch:
    // `agentPaneArguments` drops the prompt when the CLI takes none, and
    // fan-out and MCP then both report success on an agent that came up bare.
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

    // A resume continues a conversation we may already have a row for; minting
    // a second left the dead row and the new one both answering to the same CLI
    // id. Resolved *before* the permission mode, because resolving the mode
    // first wrote the setting over the row it was about to reuse and discarded
    // the mode chosen on the composer chip. The `??` is not a precedence
    // decision — restart and resume are mutually exclusive by the guard above.
    final reused =
        _reusableRowForResume(request) ?? _reusableRowForRestart(request);

    // In priority order: what a caller resolved for this launch, else the row's
    // own choice. Null means nobody chose, and the setting answers — live.
    final chosenMode =
        request.permissionOverride?.canonical ?? reused?.permissionMode;
    final permissionMode = permissionFor(
      request.installation.agentId,
      request.purpose,
      sessionMode: chosenMode,
    );

    // The same rule one line down; null all the way means no model flag at all.
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
    // The launch directory, except when we fell back off one that has gone
    // away.
    var recordDirectory = true;
    String? workingDirectoryNotice;
    EnvironmentPath? worktree;
    if (request.existingWorktree != null) {
      // Joining, not creating: a handoff and a same-worktree fork continue the
      // work where it is, so the receiver sees the tree the recap describes.
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
      // Where this conversation was actually running: from the caller when it
      // knows (a handoff, a fork), otherwise from the row being resumed.
      final resolved = directoryOrFallback(
        _ref,
        // The row's worktree is the same fact for a row written before schema
        // v22. Read, not turned into `worktree`: a launch must not invent one.
        directory:
            request.workingDirectory ??
            reused?.workingDirectory ??
            reused?.worktree,
        fallback: request.repository.path,
      );
      workingDirectory = resolved.directory;
      // Falling back rather than failing, but the record is kept: a missing
      // folder is often temporary — an unmounted drive, a WSL distro that is
      // not running — and forgetting it would make that permanent data loss.
      workingDirectoryNotice = resolved.notice;
      recordDirectory = resolved.notice == null;
    }

    // Asked last, because it is the first thing that needs the directory: is
    // this continuing a conversation from somewhere other than where it was
    // recorded? Joined onto the fallback's sentence — the user reads one line.
    workingDirectoryNotice = [
      ?workingDirectoryNotice,
      ?conversationElsewhereCaveat(request, workingDirectory),
    ].join(' ');
    if (workingDirectoryNotice.isEmpty) workingDirectoryNotice = null;

    // A resumed session already has a CLI id; a new one gets *ours* when the
    // agent will accept it (our ids are RFC-4122 v4, which is what
    // `--session-id` wants), so the transcript behind the chat view is
    // locatable at launch. A fork is a create — the CLI mints its own id, and
    // passing `--session-id` alongside `--fork-session` would name the one it
    // must not reuse.
    final assignsOwnId =
        request.resumeExternalSessionId == null &&
        request.forkExternalSessionId == null &&
        (descriptor?.launch.sessionIdAssignment.isSupported ?? false);
    final externalSessionId =
        request.resumeExternalSessionId ?? (assignsOwnId ? id : null);

    // A spawned session names its parent in the prompt, the only channel it
    // has. Stripped again by rebuilding the same string, never by
    // pattern-matching.
    final attribution = attributionFor(request.parentSessionId);
    final firstMessage = attribution == null || request.firstMessage == null
        ? request.firstMessage
        : attribution.render(request.firstMessage!);

    // Reusing keeps the row's own identity — title, creation time, lineage,
    // worktree — so "continue this session" cannot quietly rename or re-date
    // it.
    final session =
        reused?.copyWith(
          status: SessionStatus.running,
          // `copyWith` keeps the row's own mode when this is null: a resume
          // must not overwrite a choice, nor freeze a session that never made
          // one.
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
          // The directory the process is about to start in — the same fact an
          // adopted session records; two sources for it would drift.
          workingDirectory: recordDirectory ? workingDirectory : null,
          status: SessionStatus.running,
          createdAt: _ref.read(clockProvider).nowUtc(),
          externalSessionId: externalSessionId,
          parentSessionId: request.parentSessionId,
          // A parent with no stated reason is a spawn — what the MCP path still
          // means when it names a caller without saying more.
          parentLink: request.parentSessionId == null
              ? null
              : (request.parentLink ?? SessionLink.spawn),
          surface: request.surface,
          view: request.view ?? defaultViewFor(descriptor),
          // Only what was **chosen**: stamping the resolved default here froze
          // every session at whatever Settings said the day it started. The
          // effective mode is [resolveSessionPermission] of this row and the
          // live setting, which is what the chip and the next launch compute.
          permissionMode: request.permissionOverride?.canonical,
          // Only what was chosen, for the reason above.
          modelId: request.modelOverride,
        );
    final dao = _ref.read(sessionDaoProvider);
    if (reused == null) {
      dao.insert(session);
    } else {
      dao.updateStatus(id, SessionStatus.running);
      // Written only when this launch carries a decision: writing the resolved
      // mode unconditionally destroyed the chip's choice on the next resume.
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
    // is named by [id]. Every "no" falls back to the opening prompt.
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
      // The row must not outlive a launch that never happened.
      dao.updateStatus(id, SessionStatus.failed);
      // The same word as the success path: the row still appeared, and a failed
      // launch must reach every list that draws it.
      _publish(_whatALaunchMoved(request, id, reused: reused != null));
      rethrow;
    }
  }

  /// What a launch actually moved, named rather than shouted. A bare `bump()`
  /// raises `SessionSignals.broadcasts`, the floor under **every** per-row
  /// watcher, so creating one session re-read every row and re-scanned every
  /// dead pane synchronously inside the frame — see
  /// `session_start_cost_test.dart` for the measurement.
  SessionChange _whatALaunchMoved(
    SessionLaunchRequest request,
    String id, {
    required bool reused,
  }) => SessionChange(
    sessionId: id,
    kinds: {
      // Every watcher of the list watches membership anyway, so this is the
      // only kind the create and resume cases differ on.
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
  /// this launch genuinely creates a session. Narrow on purpose: a create or a
  /// fork, a new worktree, a stated parent, a live candidate, a different
  /// repository/installation/surface, or an archived row each mean two rows is
  /// the honest answer.
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

  /// The row a [SessionLaunchRequest.restartSessionId] launch continues *as* —
  /// the same guards as [_reusableRowForResume], but the row is named directly,
  /// because a restart's premise is that no conversation exists to look it up
  /// by. `assignsOwnId` stays true, so the row's own id is stamped again.
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
