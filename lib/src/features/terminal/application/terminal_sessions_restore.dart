part of 'terminal_sessions_controller.dart';

// `Notifier.ref` is `@protected`, which covers a subclass and not an
// extension — even one splitting that subclass's own body inside its own
// library, which is all any part of this file is.
// ignore_for_file: invalid_use_of_protected_member

/// Reading the layout back: rebuilding the tabs and their splits, putting them
/// into the groups they were in, and giving a pane either a process or the
/// buffer it was stored with.
///
/// Defensive at every step by design — a layout that will not parse, a profile
/// that no longer exists, a tab left with nothing in it — because a corrupt
/// row must never make the terminal unopenable.
extension TerminalLayoutRestore on TerminalSessionsController {
  /// Recreates the stored layout: the tabs, the splits inside them, and each
  /// pane's scrollback — as a **dormant** buffer, except for the panes of the
  /// active tab that were running when the app closed, which get a process back.
  ///
  /// The owner, twice: *"why when app restart the active pane doesn't
  /// automatically resume the session? why must i tap start again"*, and then
  /// *"if there were active panes on last close start all those panes on active
  /// tab"*. `shouldRestartOnLaunch` holds the whole of which panes those are and
  /// why the others are still records; the ones it refuses come back exactly as
  /// they always did, marked restored with an explicit Start.
  ///
  /// A restarted pane is built **here**, in place of the dormant one, rather
  /// than started afterwards through [startPane]. Three things follow from that
  /// and all three are the point: nothing publishes state during `build` (which
  /// Riverpod forbids), the first frame already shows a live terminal instead of
  /// a "Session ended" bar that vanishes, and the stored scrollback is parsed
  /// once — where starting afterwards would build the dormant pane's buffer and
  /// then throw it away.
  ///
  /// Defensive at every step: a layout that will not parse, a pane whose profile
  /// no longer exists, a tab left with nothing in it — each is dropped rather
  /// than thrown on, because a corrupt row must never make the terminal
  /// unopenable. The worst case is an empty layout, which is what a first run
  /// looks like anyway.
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
      // Which tab counts as "the active tab" has to be decided before any pane
      // is built, and the same way the fallback below decides it: a layout
      // stored with no active row activates its last tab. Resolved against the
      // *stored* list rather than the rebuilt one, so a last tab that turns out
      // to be unrebuildable starts nothing rather than promoting another tab's
      // panes into a decision the user never made.
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
            // `activate` restates the invariant rather than trusting it: the
            // stored front pane of a region may be one of the panes that could
            // not be rebuilt, and the focused pane has to be the one on screen.
            layout: kept ? layout.activate(stayed) : layout,
            focusedPaneId: kept ? stayed : layout.visiblePanes.first,
          ),
        );
        _tabsMutated();
        if (storedTab.id == stored.activeTabId) _activeTabId = storedTab.id;
      }

      // Sessions that had no tab last time stay tab-less: they come back in the
      // background list, where the user reopens the ones still worth having.
      // They are in no tab, so they are never in the *active* one, and a
      // detached session is precisely the thing the user already closed the
      // view of — starting one would spawn a process with nowhere to show it.
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

  /// Puts the tabs that came back into the groups they were in.
  ///
  /// Pruned against the tabs that actually rebuilt, the same way a tab's own
  /// layout is: a group naming only tabs that could not be restored collapses,
  /// and a tab the tree never heard of joins the focused group when
  /// [_reconcileWorkspace] next runs. A tree that will not parse is no tree,
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

  /// Rebuilds [pane]: with a process when it earned one, and as a process-free
  /// buffer holding its stored scrollback when it did not.
  ///
  /// Returns false when the pane's profile no longer resolves — a WSL distro
  /// that has been removed, say — since there would be nothing to start it with.
  bool _adoptRestored(StoredTerminalPane pane, {required bool inActiveTab}) {
    // A document is rebuilt by being drawn, so there is nothing to adopt and
    // nothing that could fail to resolve — but it is still here, which is what
    // the true says and what keeps `withoutMissing` from dropping its leaf.
    if (isDocumentPane(pane.id)) return true;
    // An agent pane carries its own command, so it does not need — and never
    // had — a resolvable shell profile.
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
        // Remembered so opening this tab later can start what was running in
        // it — the launch rule only ever covers the tab left in front.
        wasLive: pane.wasLive,
        gridHint: _gridHint,
      ),
    );
    return true;
  }

  /// Gives [pane] a process again, replaying its stored scrollback above it.
  ///
  /// The same factory every other pane comes from, so a shell that will not
  /// spawn degrades exactly as it does anywhere else: to an
  /// [ErrorTerminalInstance] holding the reason above the history, reported as
  /// [PaneLiveness.exited] with a Restart on it. A pane that cannot start says
  /// so; it never comes back as a blank buffer pretending to be a shell.
  ///
  /// Returns false — and the caller falls back to the dormant pane — if the
  /// factory *throws* rather than degrading. Nothing in production does that,
  /// and this runs inside the restore: a layout must not be lost because one
  /// pane could not be started.
  bool _adoptRestarted(StoredTerminalPane pane, TerminalProfile profile) {
    final TerminalInstance instance;
    // Only the build is guarded, so a refusal is always a pane that was never
    // adopted — there is no half-adopted state for the dormant fallback to be
    // laid over.
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
    // The buffer this pane came back with *is* the stored scrollback, replayed.
    // Without seeding, the first structural save of the run — the one that
    // follows the user's first click — encodes every restarted pane in full to
    // learn what the store already read out to it. See [_seedEncoding].
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
