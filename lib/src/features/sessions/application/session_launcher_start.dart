part of 'session_launcher.dart';

/// **The** way a session comes into existence, and how one is re-created on
/// the same conversation. A `part` because privacy in Dart is per library.
extension SessionStartVerbs on SessionLauncher {
  /// Ends the agent [sessionId] is running and starts a new one on the same
  /// conversation. Every refusal happens before anything is killed.
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

    // Before the kill, because ending is not undoable and a restart onto a
    // CLI that has moved would take the agent down and put nothing back.
    final startable = await usableInstallation(installation);

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
        installation: startable,
        title: session.title,
        purpose: SessionPurpose.existingSession,
        resumeExternalSessionId: externalId,
        // So [_reusableRowForResume] continues *this* row rather than minting
        // a second: it compares the request's surface against the candidate's.
        surface: session.surface,
      ),
    );
  }

  /// The body of [SessionLauncher.launch], which stays on the class: two test
  /// doubles subclass it, and an extension member cannot be overridden.
  Future<SessionLaunchResult> _launch(
    SessionLaunchRequest request, {
    SystemTerminal? externalTerminal,
  }) async {
    // Refused on the shape of the request alone: the reuse below silently
    // prefers the resume, so falling through hands the user the other thing.
    if (request.restartSessionId != null &&
        (request.resumeExternalSessionId != null ||
            request.forkExternalSessionId != null)) {
      throw ArgumentError(
        'A launch cannot restart a session and also resume or fork a '
        'conversation.',
      );
    }

    // A resume of a conversation we are still running would be a second agent
    // on it — but for one that permits that, it is what was asked for.
    refuseIfForbidden(
      agentId: request.installation.agentId,
      externalSessionId: request.resumeExternalSessionId,
    );

    // Before every write below and before the only refusal that performs one:
    // a stored path is state, and the boot sweep's reading ages out mid-session.
    request = request.withInstallation(
      await usableInstallation(request.installation),
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
    // fan-out and MCP would both report success on an agent that came up bare.
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

    // Resolved *before* the permission mode: the other order wrote the setting
    // over the row it was about to reuse, discarding the chip's own choice.
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
      // folder is often temporary, and forgetting it is permanent data loss.
      workingDirectoryNotice = resolved.notice;
      recordDirectory = resolved.notice == null;
    }

    // Asked last, because it needs the directory. Joined onto the fallback's
    // sentence — one substitution, one line for the user to read.
    workingDirectoryNotice = [
      ?workingDirectoryNotice,
      ?conversationElsewhereCaveat(request, workingDirectory),
    ].join(' ');
    if (workingDirectoryNotice.isEmpty) workingDirectoryNotice = null;

    // A new session gets *our* id where the agent accepts one (RFC-4122 v4,
    // what `--session-id` wants); a fork is a create and mints its own.
    final assignsOwnId =
        request.resumeExternalSessionId == null &&
        request.forkExternalSessionId == null &&
        (descriptor?.launch.sessionIdAssignment.isSupported ?? false);
    final externalSessionId =
        request.resumeExternalSessionId ?? (assignsOwnId ? id : null);

    // A spawned session names its parent in the prompt, the only channel it
    // has; stripped by rebuilding the string, never by pattern-matching.
    final attribution = attributionFor(request.parentSessionId);
    final firstMessage = attribution == null || request.firstMessage == null
        ? request.firstMessage
        : attribution.render(request.firstMessage!);

    // Reusing keeps the row's own identity, so "continue this session" cannot
    // quietly rename or re-date it.
    final session =
        reused?.copyWith(
          status: SessionStatus.running,
          // `copyWith` keeps the row's own mode when this is null: a resume
          // must neither overwrite a choice nor freeze one never made.
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
          // every session at whatever Settings said the day it started.
          permissionMode: request.permissionOverride?.canonical,
          // Only what was chosen, for the reason above.
          modelId: request.modelOverride,
        );
    final dao = _ref.read(sessionDaoProvider);
    // One transaction: a row with no repository link is a session no list can
    // place, and a link that failed must not leave one behind.
    _ref.read(databaseProvider).transaction(() {
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
    });

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
        SessionSurface.pane => await _startInPane(
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
          externalTerminal: externalTerminal,
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

  /// What a launch actually moved, named rather than shouted: a bare `bump()`
  /// wakes every per-row watcher — see `session_start_cost_test.dart`.
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
  /// this launch genuinely creates a session. Narrow on purpose.
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
  /// named directly, because a restart has no conversation to look it up by.
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
