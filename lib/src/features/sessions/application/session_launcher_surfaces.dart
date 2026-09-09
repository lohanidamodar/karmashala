part of 'session_launcher.dart';

/// Putting the process somewhere: a PTY pane inside the app, or a terminal
/// window we do not own — and the two things a launch hands it that only
/// exist once a directory is known.
///
/// The two starters are deliberately the same launch twice. They resolve the
/// environment through the one resolver, ask for MCP access the same way, and
/// build their arguments from the same `agentPaneArguments`, because "open
/// this in Windows Terminal instead" must produce the same agent, in the same
/// mode, on the same conversation. What differs is only the wrapper the
/// process is started under, which the environment decides.
///
/// The handoff packet's file is written here for the same reason: it is named
/// by the session it belongs to and spelled in the path namespace of the
/// environment the agent runs in, and both of those are only known this late.
/// Every "no" along the way falls back to the opening prompt rather than
/// failing the launch.
///
/// An extension in a `part` for the reason `session_launcher.dart` gives —
/// these are private members of the class, called from `_launch`.
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
      // The two halves are kept apart on the record rather than joined into one
      // list: this is the launch the pane is *stored* as, and the MCP flags are
      // dead the moment this app process is. `commandArguments` puts them back
      // together in the order the agents want.
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
    // A session whose pane was restored but never started already has a
    // terminal: the one holding everything it printed before the app was last
    // closed. Running the resume *in* it continues that record, where opening a
    // second pane would leave the user two terminals for one session — the
    // dormant one the workbench shows, and a live one beside it.
    //
    // Only a dormant pane. `reveal` has already brought back a live one, and an
    // exited pane is this run's record of a process that stopped rather than
    // history waiting to be continued.
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
    // Deliberately after the pane is claimed, so it reports what happened
    // rather than what was intended. `resumed` is the dormant-pane reuse: when
    // it is false for a session that has a restored pane, the user is about to
    // be looking at two terminals for one session.
    _log.info(
      'Started ${session.id} in a pane: agent=${request.installation.agentId} '
      'mode=${permissionMode.canonical} model=${modelId ?? 'agent default'} '
      'pane=${opened.paneId} '
      'resumed=${resumedTab != null} '
      'conversation=${request.resumeExternalSessionId ?? 'new'} '
      'worktree=${request.useWorktree} '
      // The ordinary answer is often "none" and that is not an error — but it
      // is the answer to "why can't the agent see Karmashala's tools", which
      // was previously only discoverable by reading the launched command line.
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
  /// agent** names it, or `null` when there is none to hand.
  ///
  /// Four honest `null`s, and each is reported rather than silently taken: the
  /// request carries no packet, the agent declares no such option (or nobody
  /// checked, which is a different sentence and gets one), the environment has
  /// no name for the path — an SSH agent is on another disk — or the write
  /// failed. In every case the caller's text is still the opening prompt.
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
        // The sweep, and the only one: this directory grows on a handoff and
        // on nothing else, so a handoff is the occasion to retire what is no
        // longer wanted. Nothing polls (CLAUDE.md 19).
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

  /// How this session will reach Karmashala's own tools, or `null` when it
  /// will not.
  ///
  /// Both surfaces call this and then hand the result to [agentPaneArguments],
  /// which is the same reason they share that function: "open this in Windows
  /// Terminal instead" must produce the same agent, on the same endpoint,
  /// speaking as the same session.
  ///
  /// `null` is the ordinary answer and never an error. The control server is
  /// not up; the agent has no verified convention; the session runs over SSH,
  /// or in WSL on a host with no switch to dial; the config directory could not
  /// be locked down. In every case the launch is byte-identical to the one that
  /// happened before any of this existed — which is the property that matters
  /// most, because a session that opens without its tools is a smaller loss
  /// than a session that does not open.
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
