part of 'session_launcher.dart';

/// Putting the process somewhere: a PTY pane inside the app, or a terminal
/// window we do not own — and the two things a launch hands it that only exist
/// once a directory is known.
///
/// The two starters are deliberately the same launch twice: one resolver, one
/// way of asking for MCP access, one `agentPaneArguments`, because "open this
/// in Windows Terminal instead" must produce the same agent, in the same mode,
/// on the same conversation. Only the wrapper differs, and the environment
/// decides that. The handoff packet's file is written here because it is named
/// by the session and spelled in the agent's own path namespace, both known
/// only this late; every "no" falls back to the opening prompt.
extension SessionSurfaceStarters on SessionLauncher {
  SessionLaunchResult _startInPane(
    Session session,
    SessionLaunchRequest request,
    AgentDescriptor? descriptor,
    PermissionSelection permissionMode,
    String? modelId,
    EnvironmentPath workingDirectory,
    bool assignsOwnId,
    String? firstMessage,
    String? systemPromptFilePath,
    String? workingDirectoryNotice,
  ) {
    // The one resolver: this is the launch that CLAUDE.md 17 is about, and a
    // wrong environment here is silent for whoever ran it.
    final environment = _ref
        .read(environmentResolverProvider)
        .resolveFor(workingDirectory)
        .require;
    final mcp = _mcpAccessFor(session, descriptor, environment);
    final launch = AgentPaneLaunch(
      agentId: request.installation.agentId,
      executable: request.installation.executable.path,
      // Kept apart on the record rather than joined into one list: this is the
      // launch the pane is *stored* as, and the MCP flags are dead the moment
      // this app process is.
      arguments: agentPaneArguments(
        descriptor,
        permissionMode,
        modelId: modelId,
        sessionId: assignsOwnId ? session.id : null,
        resumeSessionId: request.resumeExternalSessionId,
        forkSessionId: request.forkExternalSessionId,
        prompt: firstMessage,
        systemPromptFilePath: systemPromptFilePath,
      ),
      mcpArguments: agentMcpArguments(
        descriptor,
        url: mcp?.url,
        configPath: mcp?.configPath,
      ),
      workingDirectory: workingDirectory.path,
      wslDistribution: environment.wslDistribution,
      sshHostId: environment.sshHostId,
      sessionId: session.id,
      title: session.title,
    );
    final terminals = _ref.read(terminalSessionsControllerProvider.notifier);
    // A session whose pane was restored but never started already has the
    // terminal holding everything it printed before the app was last closed;
    // resuming *in* it continues that record instead of leaving the user two
    // terminals for one session. Only a dormant pane: `reveal` has already
    // brought back a live one, and an exited pane is this run's own record.
    final dormant = dormantPaneFor(session.id);
    final resumedTab = dormant == null
        ? null
        : terminals.startAgentInPane(dormant, launch);
    final slotted = dormant == null && request.targetPaneId != null
        ? terminals.openAgentInSlot(request.targetPaneId!, launch)
        : null;
    final opened = resumedTab != null
        ? (tabId: resumedTab, paneId: dormant!)
        : slotted ?? terminals.openAgentTab(launch);
    _ref.read(sessionDaoProvider).updatePaneId(session.id, opened.paneId);
    _ref.read(terminalSessionsControllerProvider.notifier).showTerminalForPane(opened.paneId);
    // After the pane is claimed, so it reports what happened rather than what
    // was intended. `resumed` false for a session that has a restored pane
    // means the user is about to be looking at two terminals for one session.
    _log.info(
      'Started ${session.id} in a pane: agent=${request.installation.agentId} '
      'mode=${permissionMode.canonical} model=${modelId ?? 'agent default'} '
      'pane=${opened.paneId} '
      'resumed=${resumedTab != null} '
      'conversation=${request.resumeExternalSessionId ?? 'new'} '
      'worktree=${request.useWorktree} '
      // Often "none", which is not an error — but it is the answer to "why
      // can't the agent see Karmashala's tools".
      'mcp=${mcp == null ? 'none' : 'yes'}',
    );
    return SessionLaunchResult(
      session: session.copyWith(paneId: opened.paneId),
      paneId: opened.paneId,
      tabId: opened.tabId,
      workingDirectoryNotice: workingDirectoryNotice,
    );
  }

  Future<SessionLaunchResult> _startInExternalTerminal(
    Session session,
    SessionLaunchRequest request,
    AgentDescriptor? descriptor,
    PermissionSelection permissionMode,
    String? modelId,
    EnvironmentPath workingDirectory,
    bool assignsOwnId,
    String? firstMessage,
    String? systemPromptFilePath,
    String? workingDirectoryNotice,
  ) async {
    // The same resolver as the pane path, so the two surfaces cannot drift.
    final environment = _ref
        .read(environmentResolverProvider)
        .resolveFor(workingDirectory)
        .require;
    final terminal =
        request.externalTerminal ??
        await _ref.read(defaultSystemTerminalProvider.future);
    if (terminal == null) {
      throw StateError('No external terminal is configured.');
    }
    final mcp = _mcpAccessFor(session, descriptor, environment);
    final agentCommand = [
      request.installation.executable.path,
      ...agentPaneArguments(
        descriptor,
        permissionMode,
        modelId: modelId,
        sessionId: assignsOwnId ? session.id : null,
        resumeSessionId: request.resumeExternalSessionId,
        forkSessionId: request.forkExternalSessionId,
        prompt: firstMessage,
        systemPromptFilePath: systemPromptFilePath,
        mcpUrl: mcp?.url,
        mcpConfigPath: mcp?.configPath,
      ),
    ];
    final distro = environment.wslDistribution;
    // Same wrapper decision as the pane and the resume paths, from the same
    // function: the environment says whether the line has to cross into WSL.
    final command = wrapForExternalTerminal(
      ShellCommand(
        executable: agentCommand.first,
        arguments: agentCommand.sublist(1),
        workingDirectory: workingDirectory.path,
      ),
      LaunchContext.forEnvironment(distro),
    );
    await _ref
        .read(systemTerminalServiceProvider)
        .launch(
          terminal,
          command: command,
          workingDirectory: distro == null ? workingDirectory.path : null,
        );
    return SessionLaunchResult(
      session: session,
      workingDirectoryNotice: workingDirectoryNotice,
    );
  }

  /// The system-prompt file this launch hands its agent, spelled as **that
  /// agent** names it, or `null` when there is none to hand. Four honest nulls,
  /// each reported rather than silently taken: no packet, no declared option
  /// (or nobody checked, which is a different sentence), no name for the path
  /// in this environment, or the write failed. The caller's text is still the
  /// opening prompt.
  Future<String?> _systemPromptFileFor({
    required String sessionId,
    required SessionLaunchRequest request,
    required AgentDescriptor? descriptor,
    required EnvironmentPath directory,
  }) async {
    final content = request.systemPromptFile?.trim();
    if (content == null || content.isEmpty) return null;
    final support =
        descriptor?.launch.systemPromptFile ??
        const AgentSystemPromptFileSupport.unchecked();
    if (!support.isSupported) {
      _log.info(
        'Handoff packet for $sessionId stays in the opening prompt: '
        '${descriptor?.displayName ?? request.installation.agentId} '
        '${support.wasChecked ? 'has no system-prompt file option (${support.evidence})' : 'has never been checked for one'}',
      );
      return null;
    }
    final kind = _ref
        .read(executionEnvironmentDaoProvider)
        .getById(directory.environmentId)
        ?.kind;
    final path = kind == null
        ? null
        : await _writeSystemPromptFile(sessionId, content, kind);
    _log.info(
      'Handoff packet for $sessionId: '
      '${path == null ? 'stays in the opening prompt — no path this agent could open' : 'handed over as ${support.token} $path'}',
    );
    return path;
  }

  Future<String?> _writeSystemPromptFile(
    String sessionId,
    String content,
    EnvironmentKind kind,
  ) async {
    try {
      final files = await _ref.read(handoffPacketFilesProvider.future);
      final written = files.write(
        sessionId: sessionId,
        packet: content,
        // The sweep, and the only one: this directory grows on a handoff and on
        // nothing else, so a handoff is the occasion to retire what is stale.
        liveSessionIds: {
          for (final row in _ref.read(sessionDaoProvider).getAll())
            if (row.status == SessionStatus.running) row.id,
        },
      );
      return written == null ? null : agentConfigPathFor(written, kind);
    } on Object {
      // No support directory (a headless test container), a locked file, a
      // provider that could not build. None of it is worth failing a launch.
      return null;
    }
  }

  /// How this session will reach Karmashala's own tools, or `null` when it will
  /// not. Both surfaces call this and hand the result to [agentPaneArguments],
  /// so an external terminal gets the same agent on the same endpoint speaking
  /// as the same session. `null` is the ordinary answer and never an error —
  /// the launch is then byte-identical to the one that happened before any of
  /// this existed, because a session that opens without its tools is a smaller
  /// loss than a session that does not open.
  SessionMcpAccess? _mcpAccessFor(
    Session session,
    AgentDescriptor? descriptor,
    ExecutionEnvironment environment,
  ) => sessionMcpAccessFor(
    _ref,
    sessionId: session.id,
    descriptor: descriptor,
    environment: environment,
  );
}
