part of 'terminal_sessions_controller.dart';

// `Notifier.ref` is `@protected`, which covers a subclass and not an
// extension — even one splitting that subclass's own body inside its own
// library, which is all any part of this file is.
// ignore_for_file: invalid_use_of_protected_member

/// **Session lifetime, as distinct from view lifetime**: re-attaching a
/// detached session, ending one for real, ending all of them, and starting or
/// resuming a process in a pane that already exists.
///
/// The distinction this family exists for is that closing a tab removes a
/// *view* while the build, dev server or agent inside carries on. Everything
/// here is about the process rather than the layout.
extension TerminalSessionLifetime on TerminalSessionsController {
  /// Brings a detached session back as a new tab and focuses it.
  ///
  /// Returns the new tab's id, or `null` if nothing was detached under
  /// [paneId]. The instance is the *same object* that was running all along, so
  /// re-attaching is instantaneous and loses nothing — this is a view being
  /// reopened, not a session being recreated.
  String? reattachSession(String paneId) {
    final index = _detached.indexWhere((s) => s.paneId == paneId);
    if (index < 0) return null;
    _detached.removeAt(index);
    _detachedMutated();

    final tabId = _newTabFor(paneId);
    _publish();
    persistStructure();
    _focusActivePane();
    return tabId;
  }

  /// Ends session [paneId] for real — the deliberate counterpart to closing its
  /// tab.
  ///
  /// The process is asked to exit and then killed if it will not (Loop 32's
  /// escalation, via the instance's `dispose`). Works whether the pane is in a
  /// tab or detached.
  void endSession(String paneId) {
    _userClosedSinceRestore = true;
    if (_tabContaining(paneId) != null) {
      closePane(paneId, detach: false);
      return;
    }
    _detached.removeWhere((s) => s.paneId == paneId);
    _detachedMutated();
    _releasePane(paneId);
    _publish();
    persistStructure();
  }

  /// Ends every detached session at once — the "I am done with all of these"
  /// escape hatch, so background sessions can never quietly pile up.
  void endAllDetached() {
    if (_detached.isEmpty) return;
    _userClosedSinceRestore = true;
    for (final session in List.of(_detached)) {
      _releasePane(session.paneId);
    }
    _detached.clear();
    _detachedMutated();
    _publish();
    persistStructure();
  }

  /// Every pane in a tab holding **restored agent history**: a session that was
  /// open when the app was last closed, rebuilt from disk with nothing running
  /// behind it.
  ///
  /// What "resume all" acts on, and what the toolbar counts. In tab order and
  /// then in each tab's own pane order, so a bulk resume walks them the way the
  /// user laid them out rather than the way a hash map happens to.
  ///
  /// **Detached panes are deliberately absent.** A session with no tab belongs
  /// to the background list and is reopened from [BackgroundSessionsDialog];
  /// counting it here as well would put one session in two dialogs, each
  /// offering a different verb for it.
  ///
  /// Shell panes are absent for the reason `shouldResumeRatherThanRestart`
  /// gives: there is no conversation to continue in one, and its Start button
  /// already does the right thing on its own.
  List<String> restoredAgentPanes() => [
    for (final tab in _tabs)
      for (final paneId in tab.layout.panes)
        if (_isRestoredAgentPane(paneId)) paneId,
  ];

  bool _isRestoredAgentPane(String paneId) {
    final instance = _instances[paneId];
    return instance != null &&
        instance.agentLaunch != null &&
        instance.liveness.value == PaneLiveness.restored;
  }

  /// Starts a process in [paneId], replaying whatever is already in its buffer
  /// above the new one.
  ///
  /// This is the only way a pane the launch declined to restart gets a process
  /// — an agent pane, a background tab, a pane whose process had already
  /// exited, or any pane at all when the setting is off — so restarting the app
  /// can still never re-execute a build or an agent behind the user's back.
  /// Also the retry path for a pane whose process exited or failed to spawn.
  ///
  /// What a launch *does* start, and why those cases are different, is
  /// `shouldRestartOnLaunch`; it builds the pane live rather than coming
  /// through here.
  ///
  /// Does nothing for a pane that is already live.
  void startPane(String paneId) {
    final existing = _instances[paneId];
    if (existing == null || existing.liveness.value.isLive) return;
    // An agent pane is restarted from its recorded command, not from a shell
    // profile: `agent:<id>` deliberately does not resolve as one. What it is
    // *not* restarted with is the MCP flags of the run that recorded it — see
    // [_liveMcpArgumentsFor].
    final recorded = existing.agentLaunch;
    final agentLaunch = recorded?.withMcpArguments(
      _liveMcpArgumentsFor(recorded),
    );
    final profile = agentLaunch != null
        ? TerminalProfile.powerShell
        : terminalProfileFromId(existing.profileId);
    if (profile == null) return;

    // The buffer this pane is already holding, when it has one worth taking:
    // the history is then handed over rather than encoded out and parsed back
    // in. Otherwise a dormant pane hands back exactly what was restored and a
    // parked one the window it kept; a pane whose buffer we can neither adopt
    // nor read as text has to be re-encoded.
    final adopt = _adoptableBufferOf(existing);
    final scrollback = adopt != null
        ? null
        : _heldScrollbackOf(existing) ?? encodeScrollback(existing.terminal);
    final workingDirectory = existing.workingDirectory;
    // Taken before the release, which drops it: this is the history the new
    // pane starts from, and handing it on is what stops the save below
    // encoding it back out again. See [_seedEncoding].
    final carried = scrollback ?? _encoded[paneId] ?? _heldScrollbackOf(existing);

    _releasePane(paneId);
    _adopt(
      paneId,
      ref.read(terminalInstanceFactoryProvider)(
        id: paneId,
        profile: profile,
        workingDirectory: workingDirectory,
        restoredScrollback: scrollback,
        shellIntegration: _shellIntegrationEnabled,
        agentLaunch: agentLaunch,
        adoptTerminal: adopt,
      ),
    );
    _seedEncoding(paneId, carried);
    _publish();
    persistStructure();
    _focusActivePane();
  }

  /// The MCP flags a pane started **now** should carry, which are never the
  /// ones it was started with before.
  ///
  /// Every value in those flags belongs to one run of the app: the config
  /// directory is deleted on the way in, the control server binds whatever port
  /// it can get, and the URL's last segment is a credential minted for this
  /// process. A restored pane used to replay all three, and the agent refused
  /// to start at all:
  ///
  ///   Error: Invalid MCP configuration:
  ///   MCP config file not found: `…/karmashala/mcp/session-<uuid>.json`
  ///
  /// An empty answer is the ordinary one — no server, no session row, a
  /// terminal-only container — and it is the right one: a pane without its
  /// tools is a smaller loss than a pane that will not open, which is the trade
  /// `SessionLauncher` already makes at the original launch.
  List<String> _liveMcpArgumentsFor(AgentPaneLaunch launch) {
    try {
      return ref.read(agentPaneMcpArgumentsProvider)(launch);
    } catch (_) {
      return const [];
    }
  }

  /// Runs [launch] in the pane [paneId] already has, keeping everything in its
  /// buffer, and brings that pane back on screen. Returns the tab it is now in,
  /// or `null` when there is no such pane or something is still running in it.
  ///
  /// The counterpart to [openAgentTab] for a session that already has a pane —
  /// which, after a restart, every restored session does. That pane is the
  /// session's own record of itself and the reason its scrollback was kept, so
  /// resuming *into* it is what leaves the user one terminal for one session
  /// rather than a dormant pane and a live one side by side.
  ///
  /// Unlike [startPane] the command is the caller's, not the pane's: a resume
  /// is a different command line from the launch that was recorded, and
  /// re-running the recorded one would start a new conversation instead of
  /// continuing the stored one.
  ///
  /// Refusing a live pane is the same rule [startPane] applies, and for the
  /// same reason: the caller wants a process for this session, and taking one
  /// that is already running away from it is not that.
  String? startAgentInPane(String paneId, AgentPaneLaunch launch) {
    final existing = _instances[paneId];
    if (existing == null || existing.liveness.value.isLive) return null;

    // Asked for before the pane is released, and through the same helpers
    // [startPane] uses: the buffer is handed over when the pane has one, and a
    // dormant pane that has never been looked at hands back exactly what was
    // restored without ever building the buffer the restore did not build.
    final adopt = _adoptableBufferOf(existing);
    final scrollback = adopt != null
        ? null
        : _heldScrollbackOf(existing) ?? encodeScrollback(existing.terminal);
    // As in [startPane], and for the same reason: the history the resumed
    // pane starts from is history the store already holds.
    final carried = scrollback ?? _encoded[paneId] ?? _heldScrollbackOf(existing);
    _releasePane(paneId);
    _adopt(
      paneId,
      ref.read(terminalInstanceFactoryProvider)(
        id: paneId,
        // Unused for an agent pane, as in [openAgentTab].
        profile: TerminalProfile.powerShell,
        workingDirectory: launch.workingDirectory,
        restoredScrollback: scrollback,
        agentLaunch: launch,
        adoptTerminal: adopt,
      ),
    );
    _seedEncoding(paneId, carried);
    final tabId = _showPane(paneId);
    _publish();
    persistStructure();
    return tabId;
  }
}
