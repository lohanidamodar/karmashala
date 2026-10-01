part of 'terminal_sessions_controller.dart';

// `Notifier.ref` is `@protected`, which covers a subclass and not an extension
// splitting that subclass's own body inside its own library.
// ignore_for_file: invalid_use_of_protected_member

/// Reading the layout back: the tabs, their splits, the groups they were in,
/// and a process or a stored buffer for each pane. Defensive at every step,
/// because a corrupt row must never make the terminal unopenable.
extension TerminalLayoutRestore on TerminalSessionsController {
  /// Recreates the stored layout, each pane **dormant** unless
  /// `shouldRestartOnLaunch` accepts it. Built here: `build` may not publish.
  void _restoreLayout() {
    // Whatever the previous life of this controller decided about closing
    // things, this one starts owing the store the layout it just read.
    _userClosedSinceRestore = false;
    final dao = _dao();
    if (dao == null) return;

    try {
      _gridHint.grid = dao.loadPaneGrid();
      _writtenGrid = _gridHint.grid;
      final stored = dao.loadLayout();
      // Decided before any pane is built, against the *stored* list: a last tab
      // that turns out to be unrebuildable then starts nothing, rather than
      // promoting another tab's panes into a decision the user never made.
      final activeTabId =
          stored.activeTabId ??
          (stored.tabs.isEmpty ? null : stored.tabs.last.id);
      for (final storedTab in stored.tabs) {
        final rebuilt = <String>{};
        for (final pane in storedTab.panes) {
          if (!storedTab.layout.contains(pane.id)) continue;
          if (_adoptRestored(pane, inActiveTab: storedTab.id == activeTabId)) {
            rebuilt.add(pane.id);
          }
        }

        final layout = storedTab.layout.withoutMissing(rebuilt);
        if (layout == null) continue;
        final stayed = storedTab.focusedPaneId;
        final kept = stayed != null && layout.contains(stayed);
        _tabs.add(
          TerminalTab(
            id: storedTab.id,
            // The stored front pane of a region may be one that could not be
            // rebuilt, and the focused pane has to be the one on screen.
            layout: kept ? layout.activate(stayed) : layout,
            focusedPaneId: kept ? stayed : layout.visiblePanes.first,
          ),
        );
        _tabsMutated();
        if (storedTab.id == stored.activeTabId) _activeTabId = storedTab.id;
      }

      // A pane an older build kept with no tab (`stored.detached`) is not
      // brought back: the server runs its session whether a pane shows it or
      // not, and Sessions — or its machine's terminals — opens it again.

      _activeTabId ??= _tabs.isEmpty ? null : _tabs.last.id;
      _restoreWorkspace(dao.loadWorkspace());
    } catch (error, stack) {
      _log.warning('Could not restore the terminal layout.', error, stack);
    }
  }

  /// Reattaches every restored pane whose terminal the server still runs —
  /// in any tab, detached or not, agent panes included (slice 5a: the
  /// server owns every local and WSL terminal, so a pane's process outlives
  /// this app by design).
  ///
  /// The launch rule keeps a restore from *re-running* things: a shell in a tab
  /// nobody is looking at, an agent whose conversation would replay. A session
  /// the server kept alive re-runs nothing, so neither concern applies, and
  /// leaving it as history was worse than idle: its Start button would have
  /// looked like the way to a second shell.
  Future<void> _reattachHostSurvivors() async {
    // First, and with nothing asked: most launches restore no history at all.
    final dormant = <String, String>{
      for (final entry in _instances.entries)
        if (entry.value case final DormantTerminalInstance pane)
          _restoredSessionId(entry.key, pane): entry.key,
    };
    if (dormant.isEmpty) return;

    final List<TerminalRecord> terminals;
    try {
      if (ref.read(serverAccessProvider) == null) return;
      terminals = await ref.read(terminalsClientProvider).list();
    } catch (error, stack) {
      // A server that cannot be asked leaves every pane as the history it
      // already is — the state before this step existed, not a worse one.
      _log.warning(
        'Could not ask the server which terminals survived.',
        error,
        stack,
      );
      return;
    }

    for (final terminal in terminals) {
      if (_disposed) return;
      if (!terminal.isLive) continue;
      final paneId = dormant[terminal.sessionId];
      // Re-checked: the user may have closed or started it while we asked.
      if (paneId == null || _instances[paneId] is! DormantTerminalInstance) {
        continue;
      }
      _attachRestored(paneId);
    }
  }

  /// The session id the server lists [pane]'s terminal under: a box's is
  /// `ssh:<hostId>/<id>` (slice 5d), as `_serverPane` names it. Keyed by the
  /// bare id, an SSH pane never matched and stayed history.
  String _restoredSessionId(String paneId, DormantTerminalInstance pane) {
    final own = terminalSessionId(
      paneId: paneId,
      agentSessionId: pane.agentLaunch?.sessionId,
    );
    final hostId =
        pane.agentLaunch?.sshHostId ??
        terminalProfileFromId(pane.profileId)?.sshHostId;
    return hostId == null ? own : boxSessionRef(hostId, own);
  }

  /// Puts restored pane [paneId] back on its server session, attaching only
  /// ([restoredPaneFactoryProvider]); where no server can be reached for
  /// panes, the Start button's own path.
  void _attachRestored(String paneId) {
    final existing = _instances[paneId];
    if (existing == null || existing.liveness.value.isLive) return;
    final profile = existing.agentLaunch != null
        ? TerminalProfile.powerShell
        : terminalProfileFromId(existing.profileId);
    if (profile == null) return;
    final adopt = _adoptableBufferOf(existing);
    final scrollback = adopt != null
        ? null
        : _heldScrollbackOf(existing) ?? encodeScrollback(existing.terminal);
    final instance = ref.read(restoredPaneFactoryProvider)(
      id: paneId,
      profile: profile,
      workingDirectory: existing.workingDirectory,
      restoredScrollback: scrollback,
      agentLaunch: existing.agentLaunch,
      adoptTerminal: adopt,
    );
    if (instance == null) {
      startPane(paneId);
      return;
    }
    final carried =
        scrollback ?? _encoded[paneId] ?? _heldScrollbackOf(existing);
    _releasePane(paneId);
    _adopt(paneId, instance);
    _seedEncoding(paneId, carried);
    _publish();
    persistStructure();
  }

  /// Puts the tabs that came back into the groups they were in, pruned against
  /// the ones that actually rebuilt. A tree that will not parse is no tree,
  /// which costs one group — what a first run has.
  void _restoreWorkspace(WorkspaceLayout? stored) {
    if (stored == null) return;
    final live = {for (final tab in _tabs) tab.id};
    final keep = {
      for (final id in stored.panes)
        if (live.contains(id) || isEmptyGroupSlot(id)) id,
    };
    if (keep.isEmpty) return;
    _workspace = stored.withoutMissing(keep);
    _writtenWorkspace = _workspace;
  }

  /// Rebuilds [pane], with a process when it earned one and as a process-free
  /// buffer otherwise. False when the profile no longer resolves — a removed
  /// WSL distro, say — since there would be nothing to start it with.
  bool _adoptRestored(StoredTerminalPane pane, {required bool inActiveTab}) {
    // A document is rebuilt by being drawn: nothing to adopt, but the true is
    // what keeps `withoutMissing` from dropping its leaf.
    if (isDocumentPane(pane.id)) return true;
    // An agent pane carries its own command, so it never needed a resolvable
    // shell profile.
    final profile = terminalProfileFromId(pane.profileId);
    if (pane.agentLaunch == null && profile == null) return false;

    if (profile != null &&
        shouldRestartOnLaunch(
          enabled: _restoreLivePanes,
          wasLive: pane.wasLive,
          inActiveTab: inActiveTab,
          isAgentPane: pane.agentLaunch != null,
        ) &&
        _adoptRestarted(pane, profile)) {
      return true;
    }

    _adopt(
      pane.id,
      DormantTerminalInstance(
        id: pane.id,
        title: pane.title,
        profileId: pane.profileId,
        workingDirectory: pane.workingDirectory,
        restoredScrollback: pane.scrollback,
        agentLaunch: pane.agentLaunch,
        // So opening this tab later can start what was running in it — the
        // launch rule only covers the tab left in front.
        wasLive: pane.wasLive,
        gridHint: _gridHint,
      ),
    );
    return true;
  }

  /// Gives [pane] a process again above its stored scrollback, degrading to an
  /// [ErrorTerminalInstance]; false only if the factory itself *throws*.
  bool _adoptRestarted(StoredTerminalPane pane, TerminalProfile profile) {
    final TerminalInstance instance;
    // Only the build is guarded, so a refusal is always a pane that was never
    // adopted — no half-adopted state for the dormant fallback to lie over.
    try {
      // Attaching only: a restore re-attaches, and a session that is gone
      // shows its record; the pane's Start asks for a new one.
      instance =
          ref.read(restoredPaneFactoryProvider)(
            id: pane.id,
            profile: profile,
            workingDirectory: pane.workingDirectory,
            restoredScrollback: pane.scrollback,
            agentLaunch: pane.agentLaunch,
          ) ??
          ref.read(terminalInstanceFactoryProvider)(
            id: pane.id,
            profile: profile,
            workingDirectory: pane.workingDirectory,
            restoredScrollback: pane.scrollback,
            shellIntegration: _shellIntegrationEnabled,
          );
    } catch (error, stack) {
      _log.warning(
        'Could not restart pane ${pane.id} on launch; it comes back as '
        'restored history instead.',
        error,
        stack,
      );
      return false;
    }
    _adopt(pane.id, instance);
    // Without seeding, the run's first structural save encodes every restarted
    // pane in full to learn what the store just read out to it.
    _seedEncoding(pane.id, pane.scrollback);
    return true;
  }

  /// The layout DAO, or `null` when its store cannot be opened.
  TerminalLayoutDao? _dao() {
    try {
      return ref.read(terminalLayoutDaoProvider);
    } catch (_) {
      return null;
    }
  }
}
