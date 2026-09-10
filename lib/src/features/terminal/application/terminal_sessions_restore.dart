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

      // Sessions that had no tab stay tab-less, in the background list: the
      // user already closed their view, and starting one would spawn a process
      // with nowhere to show it.
      for (final storedTab in stored.detached) {
        for (final pane in storedTab.panes) {
          if (!_adoptRestored(pane, inActiveTab: false)) continue;
          _detached.add(
            DetachedSession(
              paneId: pane.id,
              title: pane.title,
              workingDirectory: pane.workingDirectory,
              detachedAt: ref.read(clockProvider).nowUtc(),
            ),
          );
          _detachedMutated();
        }
      }

      _activeTabId ??= _tabs.isEmpty ? null : _tabs.last.id;
      _restoreWorkspace(dao.loadWorkspace());
    } catch (error, stack) {
      _log.warning('Could not restore the terminal layout.', error, stack);
    }
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
      instance = ref.read(terminalInstanceFactoryProvider)(
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

  /// The layout DAO, or `null` when no database is wired up.
  TerminalLayoutDao? _dao() {
    try {
      return ref.read(terminalLayoutDaoProvider);
    } catch (_) {
      return null;
    }
  }
}
