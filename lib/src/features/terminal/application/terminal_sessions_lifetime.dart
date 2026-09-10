part of 'terminal_sessions_controller.dart';

// `Notifier.ref` is `@protected`, which covers a subclass and not an extension
// splitting that subclass's own body inside its own library.
// ignore_for_file: invalid_use_of_protected_member

/// **Session lifetime, as distinct from view lifetime**: closing a tab removes
/// a view while the build or agent inside carries on. Everything here is about
/// the process rather than the layout.
extension TerminalSessionLifetime on TerminalSessionsController {
  /// Brings a detached session back as a new tab and focuses it; null if
  /// nothing was detached under [paneId]. The instance is the *same object*
  /// that was running all along — a view reopened, not a session recreated.
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

  /// Ends session [paneId] for real — the counterpart to closing its tab. The
  /// process is asked to exit and then killed if it will not. Works whether the
  /// pane is in a tab or detached.
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

  /// Every pane holding **restored agent history** — what "resume all" acts on,
  /// in the order the user laid them out.
  ///
  /// **Detached panes are absent**: they belong to the background list, and
  /// counting them here would put one session in two dialogs offering different
  /// verbs. Shell panes are absent — see `shouldResumeRatherThanRestart`.
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

  /// Starts a process in [paneId], replaying its buffer above the new one, and
  /// does nothing for a pane that is already live.
  ///
  /// The only way a pane the launch declined to restart gets a process, which
  /// is what keeps restarting the app from re-executing a build or an agent
  /// behind the user's back. What a launch does start is `shouldRestartOnLaunch`.
  void startPane(String paneId) {
    final existing = _instances[paneId];
    if (existing == null || existing.liveness.value.isLive) return;
    // An agent pane is restarted from its recorded command, not a shell
    // profile — but never with the recorded run's MCP flags, see
    // [_liveMcpArgumentsFor].
    final recorded = existing.agentLaunch;
    final agentLaunch = recorded?.withMcpArguments(
      _liveMcpArgumentsFor(recorded),
    );
    final profile = agentLaunch != null
        ? TerminalProfile.powerShell
        : terminalProfileFromId(existing.profileId);
    if (profile == null) return;

    // Handed over rather than encoded out and parsed back in, when the pane has
    // a buffer worth taking. Only a pane whose buffer can be neither adopted
    // nor read as text has to be re-encoded.
    final adopt = _adoptableBufferOf(existing);
    final scrollback = adopt != null
        ? null
        : _heldScrollbackOf(existing) ?? encodeScrollback(existing.terminal);
    final workingDirectory = existing.workingDirectory;
    // Taken before the release drops it: handing this on is what stops the save
    // below encoding the same history back out. See [_seedEncoding].
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

  /// The MCP flags a pane started **now** should carry, never the ones it was
  /// started with before: every value in them belongs to one run of the app, and
  /// replaying them made the agent refuse to start with "MCP config file not
  /// found". Empty is the ordinary answer — a pane without its tools is a
  /// smaller loss than a pane that will not open.
  List<String> _liveMcpArgumentsFor(AgentPaneLaunch launch) {
    try {
      return ref.read(agentPaneMcpArgumentsProvider)(launch);
    } catch (_) {
      return const [];
    }
  }

  /// Runs [launch] in the pane [paneId] already has, keeping its buffer; null
  /// when there is no such pane or one is still running in it. The command is
  /// the caller's, not the pane's — re-running the recorded launch would start
  /// a new conversation instead of continuing the stored one.
  String? startAgentInPane(String paneId, AgentPaneLaunch launch) {
    final existing = _instances[paneId];
    if (existing == null || existing.liveness.value.isLive) return null;

    // Before the release, through the same helpers [startPane] uses: a dormant
    // pane hands back what was restored without ever building a buffer.
    final adopt = _adoptableBufferOf(existing);
    final scrollback = adopt != null
        ? null
        : _heldScrollbackOf(existing) ?? encodeScrollback(existing.terminal);
    // As in [startPane]: the history the resumed pane starts from is history
    // the store already holds.
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
