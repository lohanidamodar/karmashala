part of 'session_launcher.dart';

/// **Starting a session is the server's** (slice 5b): this client names what
/// to start ([SessionStartSpec]) and shows what the server started — a tab
/// attached to the terminal it runs the agent in, a terminal window of this
/// machine for the external surface — on an SSH box too, where the server
/// starts it on the box's host (slice 5d). Every decision — the row, the directory,
/// the mode, the command line, the guards — is made there.
extension SessionStartVerbs on SessionLauncher {
  /// Ends the agent [sessionId] is running and starts it again on the same
  /// conversation, at the server.
  Future<SessionLaunchResult> restartSession(String sessionId) async {
    final started = await _ref
        .read(sessionsClientProvider)
        .resume(sessionId, restart: true);
    _log.info('Restarted $sessionId at the server to apply its mode.');
    return _show(started);
  }

  /// The body of [SessionLauncher.launch], which stays on the class: two test
  /// doubles subclass it, and an extension member cannot be overridden.
  Future<SessionLaunchResult> _launch(
    SessionLaunchRequest request, {
    SystemTerminal? externalTerminal,
  }) async {
    // A pane of ours already running this conversation is the answer to a
    // resume of it: bring it forward rather than ask for anything.
    final resuming = request.resumeExternalSessionId;
    if (resuming != null &&
        request.restartSessionId == null &&
        request.forkExternalSessionId == null) {
      final running = runningSessionWithExternalId(resuming);
      if (running != null && reveal(running.id)) {
        return SessionLaunchResult(
          session: running,
          paneId: livePaneFor(running.id),
        );
      }
    }
    final started = await _ref
        .read(sessionsClientProvider)
        .start(
          SessionStartSpec(
            repositoryId: request.repository.id,
            installationId: request.installation.id,
            title: request.title,
            titleTyped: request.titleTyped,
            newSession: request.purpose == SessionPurpose.newSession,
            surface: request.surface,
            worktree: request.useWorktree,
            worktreeBranch: request.worktreeBranch,
            worktreeBase: request.worktreeBase,
            worktreeExistingBranch: request.worktreeExistingBranch,
            existingWorktree: request.existingWorktree,
            workingDirectory: request.workingDirectory,
            additionalRepositoryIds: [
              for (final extra in request.additionalRepositories) extra.id,
            ],
            resumeConversationId: request.resumeExternalSessionId,
            restartSessionId: request.restartSessionId,
            forkConversationId: request.forkExternalSessionId,
            prompt: request.firstMessage,
            systemPrompt: request.systemPromptFile,
            parentSessionId: request.parentSessionId,
            parentLink: request.parentLink,
            permissionMode: request.permissionOverride?.canonical,
            modelId: request.modelOverride,
            view: request.view,
          ),
        );
    return _show(
      started,
      targetPaneId: request.targetPaneId,
      externalTerminal: externalTerminal,
    );
  }

  /// Shows a session the server started on another request of this client's
  /// (a handoff, a fork).
  Future<SessionLaunchResult> showStarted(SessionStarted started) =>
      _show(started);

  /// Opens [sessionId]'s conversation as a tab, or brings its tab forward.
  String _showChatTab(String sessionId) {
    final tabId = _ref
        .read(terminalSessionsControllerProvider.notifier)
        .openChatTab(sessionId);
    // Where this session is on screen moved; the workbench follows it.
    _publish(SessionChange.moved(sessionId));
    _log.info('Showing $sessionId as a chat tab: no terminal runs it here.');
    return tabId;
  }

  /// Shows what the server started: its pane brought forward, a tab attached
  /// to it, a terminal window, or — for SSH — a pane this client runs.
  Future<SessionLaunchResult> _show(
    SessionStarted started, {
    String? targetPaneId,
    SystemTerminal? externalTerminal,
  }) async {
    final session = started.session;
    _publish(SessionChange.moved(session.id));
    final external = started.external;
    if (external != null) {
      final terminal =
          externalTerminal ??
          await _ref.read(defaultSystemTerminalProvider.future);
      if (terminal == null) {
        throw StateError('No external terminal is configured.');
      }
      final distro = external.wslDistribution;
      await _ref
          .read(systemTerminalServiceProvider)
          .launch(
            terminal,
            command: wrapForExternalTerminal(
              ShellCommand(
                executable: external.executable,
                arguments: external.arguments,
                workingDirectory: external.workingDirectory,
              ),
              LaunchContext.forEnvironment(distro),
            ),
            workingDirectory: distro == null ? external.workingDirectory : null,
          );
      return SessionLaunchResult(
        session: session,
        workingDirectoryNotice: started.workingDirectoryNotice,
      );
    }
    if (reveal(session.id)) {
      return SessionLaunchResult(
        session: session,
        paneId: livePaneFor(session.id),
        workingDirectoryNotice: started.workingDirectoryNotice,
      );
    }
    final launch = started.launch;
    if (launch == null) {
      // No terminal to attach: an agent spoken to over ACP runs inside the
      // server, and its conversation is the tab.
      final tabId = installationSpeaksAcp(_ref, session.agentInstallationId)
          ? _showChatTab(session.id)
          : null;
      return SessionLaunchResult(
        session: session,
        tabId: tabId,
        workingDirectoryNotice: started.workingDirectoryNotice,
      );
    }
    final terminals = _ref.read(terminalSessionsControllerProvider.notifier);
    // A pane restored but never started already holds this session's
    // scrollback, so attaching *in* it avoids two terminals for one session.
    // Every other restored pane of it goes: one restored from an agent the
    // session has since left holds that agent's history, and a second copy
    // of the current agent's would be a second terminal on one session.
    String? dormant;
    for (final paneId
        in _ref.read(paneSessionsProvider).terminalPanesOf(session.id)) {
      final instance = terminals.instanceFor(paneId);
      if (instance?.liveness.value != PaneLiveness.restored) continue;
      if (dormant == null && instance?.agentLaunch?.agentId == launch.agentId) {
        dormant = paneId;
      } else {
        terminals.closePane(paneId, detach: true);
      }
    }
    final resumedTab = dormant == null
        ? null
        : terminals.startAgentInPane(dormant, launch);
    final slotted = dormant == null && targetPaneId != null
        ? terminals.openAgentInSlot(targetPaneId, launch)
        : null;
    final opened = resumedTab != null
        ? (tabId: resumedTab, paneId: dormant!)
        : slotted ?? terminals.openAgentTab(launch);
    _ref.read(sessionsDataProvider).updatePaneId(session.id, opened.paneId);
    terminals.showTerminalForPane(opened.paneId);
    // After the pane is named on the row: a workbench following the session
    // moves onto it now, not on the next unrelated change.
    _publish(
      SessionChange(
        sessionId: session.id,
        kinds: const {
          SessionChangeKind.membership,
          SessionChangeKind.status,
          SessionChangeKind.placement,
        },
      ),
    );
    _log.info(
      'Showing ${session.id} in pane ${opened.paneId}: '
      '${started.adopted ? 'already running at the server' : 'started by the server'}',
    );
    final notice = started.credentialNotice;
    if (notice != null) {
      _ref
          .read(sessionNoticesProvider.notifier)
          .post(session.id, SessionNotice(message: notice));
    }
    return SessionLaunchResult(
      session: session.copyWith(paneId: opened.paneId),
      paneId: opened.paneId,
      tabId: opened.tabId,
      workingDirectoryNotice: started.workingDirectoryNotice,
    );
  }
}
