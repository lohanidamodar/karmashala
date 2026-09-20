part of 'session_launcher.dart';

/// Putting the process somewhere: a PTY pane inside the app, or a terminal
/// window we do not own. The same launch twice, differing only in the wrapper.
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
    // Off by default on Windows: a self-updating agent under an unsigned
    // parent is a behavioural-antivirus dropper signal. Re-derived per launch,
    // so it is stored as neither an argument nor an env value.
    final suppressUpdate =
        descriptor != null &&
        descriptor.launch.selfUpdate.canSuppress &&
        !_ref.read(agentsMayUpdateThemselvesProvider);
    final launch = AgentPaneLaunch(
      agentId: request.installation.agentId,
      executable: request.installation.executable.path,
      // Kept apart rather than joined into one list: this is the launch the
      // pane is *stored* as, and the MCP flags die with this app process.
      arguments: agentPaneArguments(
        descriptor,
        permissionMode,
        modelId: modelId,
        sessionId: assignsOwnId ? session.id : null,
        resumeSessionId: request.resumeExternalSessionId,
        forkSessionId: request.forkExternalSessionId,
        prompt: firstMessage,
        systemPromptFilePath: systemPromptFilePath,
        suppressSelfUpdate: suppressUpdate,
      ),
      mcpArguments: agentMcpArguments(
        descriptor,
        url: mcp?.url,
        configPath: mcp?.configPath,
      ),
      // Volatile, like the MCP flags: the self-update env of *now*.
      environment: suppressUpdate
          ? descriptor.launch.selfUpdate.disableEnvironment
          : const {},
      workingDirectory: workingDirectory.path,
      wslDistribution: environment.wslDistribution,
      sshHostId: environment.sshHostId,
      sessionId: session.id,
      title: session.title,
    );
    final terminals = _ref.read(terminalSessionsControllerProvider.notifier);
    // A pane restored but never started already holds this session's
    // scrollback, so resuming *in* it avoids two terminals for one session.
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
    _ref
        .read(terminalSessionsControllerProvider.notifier)
        .showTerminalForPane(opened.paneId);
    // After the pane is claimed, so it reports what happened. `resumed` false
    // on a restored pane means the user is about to have two terminals.
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
    String? workingDirectoryNotice, {
    SystemTerminal? externalTerminal,
  }) async {
    // The same resolver as the pane path, so the two surfaces cannot drift.
    final environment = _ref
        .read(environmentResolverProvider)
        .resolveFor(workingDirectory)
        .require;
    final terminal =
        externalTerminal ??
        await _ref.read(defaultSystemTerminalProvider.future);
    if (terminal == null) {
      throw StateError('No external terminal is configured.');
    }
    final mcp = _mcpAccessFor(session, descriptor, environment);
    // The argument half of the self-update suppression (Codex's `-c`); the
    // env half (Claude's DISABLE_AUTOUPDATER) is not layered on a terminal
    // Karmashala does not own, and is noted in docs/windows-antivirus.md.
    final suppressUpdate =
        descriptor != null &&
        descriptor.launch.selfUpdate.disableArguments.isNotEmpty &&
        !_ref.read(agentsMayUpdateThemselvesProvider);
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
        suppressSelfUpdate: suppressUpdate,
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
    // Launched into a window this app cannot see: `running` would be a claim
    // nothing observes. The agent's own hooks move the row from here.
    _ref
        .read(sessionDaoProvider)
        .updateStatus(session.id, SessionStatus.unknown);
    return SessionLaunchResult(
      session: session.copyWith(status: SessionStatus.unknown),
      workingDirectoryNotice: workingDirectoryNotice,
    );
  }

  /// The system-prompt file this launch hands its agent, spelled as **that
  /// agent** names it, or `null` — every null falls back to the opening prompt.
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

  /// How this session will reach Karmashala's own tools, or `null` — the
  /// ordinary answer, and the launch is then what it was before this existed.
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
