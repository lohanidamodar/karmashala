part of 'terminal_sessions_controller.dart';

// `Notifier.ref` is `@protected`, which covers a subclass and not an
// extension — even one splitting that subclass's own body inside its own
// library, which is all any part of this file is.
// ignore_for_file: invalid_use_of_protected_member

/// Opening, activating, re-ordering and closing **tabs**, and the small index
/// lookups every one of them goes through.
///
/// An extension rather than its own class: every verb here reads and writes
/// the notifier's own `_tabs`, so the state would have to be handed around to
/// live anywhere else. See `terminal_sessions_groups.dart` for the tree these
/// tabs hang in.
extension TerminalTabVerbs on TerminalSessionsController {
  /// Opens a new tab running [profile] and makes it active. Returns its id.
  String openTab(TerminalProfile profile, {String? workingDirectory}) {
    final tabId = _newId();
    final paneId = _createPane(profile, workingDirectory: workingDirectory);
    _tabs.add(
      TerminalTab(
        id: tabId,
        layout: PaneLayout.single(paneId),
        focusedPaneId: paneId,
      ),
    );
    _tabsMutated();
    _activeTabId = tabId;
    _publish();
    persistStructure();
    _focusActivePane();
    return tabId;
  }

  /// Opens a new tab running an agent CLI in a PTY and makes it active.
  ///
  /// This is what makes any registry agent usable without a protocol adapter:
  /// the pane is an ordinary terminal, so keep-alive, detach/reattach, scrollback
  /// persistence, search and the split tree all apply to an agent exactly as
  /// they do to a shell. Returns the new pane's id.
  ({String tabId, String paneId}) openAgentTab(AgentPaneLaunch launch) {
    final tabId = _newId();
    final paneId = _createAgentPane(launch);
    _tabs.add(
      TerminalTab(
        id: tabId,
        layout: PaneLayout.single(paneId),
        focusedPaneId: paneId,
      ),
    );
    _tabsMutated();
    _activeTabId = tabId;
    _publish();
    persistStructure();
    _focusActivePane();
    return (tabId: tabId, paneId: paneId);
  }

  /// Opens an agent session in an empty split region without creating a tab.
  ///
  /// Returns null when [slotPaneId] is stale or occupied, letting the caller
  /// fall back to [openAgentTab]. The pane is created only after the slot is
  /// validated, so that fallback never starts the agent twice.
  ({String tabId, String paneId})? openAgentInSlot(
    String slotPaneId,
    AgentPaneLaunch launch,
  ) {
    final tab = _tabContaining(slotPaneId);
    if (tab == null || !_isEmptyRegion(slotPaneId)) return null;

    final paneId = _createAgentPane(launch);
    _replaceTab(
      tab.copyWith(
        layout: tab.layout.replaceRegion(slotPaneId, PaneGroup.of(paneId)),
        focusedPaneId: paneId,
      ),
    );
    _activeTabId = tab.id;
    _focusActivePane();
    persistStructure();
    return (tabId: tab.id, paneId: paneId);
  }

  String _createAgentPane(AgentPaneLaunch launch) {
    final paneId = _newId();
    _adopt(
      paneId,
      ref.read(terminalInstanceFactoryProvider)(
        id: paneId,
        // Unused for an agent pane, but the factory's contract requires one and
        // a bogus profile would be worse than the host default.
        profile: TerminalProfile.powerShell,
        workingDirectory: launch.workingDirectory,
        agentLaunch: launch,
      ),
    );
    return paneId;
  }

  void activateTab(String id) {
    if (_activeTabId == id) return;
    _activeTabId = id;
    _restoreLivePanesIn(id);
    _publish();
    _focusActivePane();
  }

  /// Starts the panes in [tabId] that were running when the app last closed.
  ///
  /// The other half of `shouldRestartOnLaunch`, which only ever covers the tab
  /// the user was left in front of. Every other tab kept its Start button
  /// forever, even once the user opened it — so the answer to "why must I press
  /// Start?" was "because this was not the active tab at launch", which is not
  /// a reason a person can see.
  ///
  /// Waiting until the tab is opened is also what makes it cheap: the launch
  /// rule stops at the active tab to avoid spawning ten shells nobody is
  /// looking at, and a tab nobody opens still spawns nothing.
  void _restoreLivePanesIn(String tabId) {
    final tab = _tabById(tabId);
    if (tab == null) return;
    for (final paneId in tab.layout.panes) {
      final instance = _instances[paneId];
      if (instance is! DormantTerminalInstance) continue;
      if (!shouldRestartOnActivate(
        enabled: _restoreLivePanes,
        wasLive: instance.wasLive,
        isAgentPane: instance.agentLaunch != null,
      )) {
        continue;
      }
      // The Start button's own path, so opening a tab and pressing Start do
      // exactly the same thing — including how the scrollback is carried over.
      startPane(paneId);
    }
  }

  /// Moves tab [tabId] to position [toIndex], sliding the rest along.
  ///
  /// The verb behind dragging a chip along the workbench strip, and the one the
  /// strip had no equivalent of at all: *"move to re-arrange tab — all should
  /// work like normal applications"*. Remove-then-insert rather than a swap,
  /// because that is what an insertion point means — dropping the last tab on
  /// the first pushes the others right rather than exchanging two of them,
  /// which is what every browser does.
  ///
  /// **Only the order.** It does not activate the tab it moved: [activateTab]
  /// restarts the panes a tab was left holding ([_restoreLivePanesIn]), and
  /// tidying a strip must not spawn a shell. Nothing here touches focus either.
  ///
  /// Returns whether anything moved, so a drop onto the place a tab already
  /// occupies costs no publish and no layout write. Ordinals are the store's
  /// own business — see `_writeChangedRows` — so [persistStructure] is all this
  /// owes for the new order to survive a restart.
  bool reorderTab(String tabId, int toIndex) {
    // Within its own group: [toIndex] is a position in the strip the chip was
    // dragged along, and every group has a strip of its own now.
    final tree = _workspace;
    if (tree == null || _tabById(tabId) == null) return false;
    final next = tree.reorderInGroup(tabId, toIndex);
    if (identical(next, tree)) return false;
    _workspace = next;
    _publish();
    persistStructure();
    return true;
  }

  /// Closes tab [id].
  ///
  /// Closing a tab is a *view* action, so by default every pane in it that still
  /// has a running process is detached rather than killed — the whole point of
  /// keep-alive. Panes with nothing running behind them are simply dropped;
  /// there is no session there to keep. Pass `detach: false` to end them for
  /// real, which is what "End session" does.
  void closeTab(String id, {bool detach = true}) =>
      closeTabs([id], detach: detach);

  /// Closes every tab in [ids] at once.
  ///
  /// The verb behind the tab menu's *Close others / to the right / to the left
  /// / all*, and — with one id — behind [closeTab] itself. Deliberately **not**
  /// a loop over [closeTab]: that would publish and write the layout once
  /// per tab, so clearing twenty tabs would rebuild every consumer twenty times
  /// and save the whole layout twenty times over. One bulk close is one
  /// publish and one save, whatever the count.
  ///
  /// [detach] means what it means in [closeTab]. [activate] names the tab to
  /// leave in front when the active one is among those closed — the tab the
  /// menu was opened from, which survives every scope but *close all*; without
  /// it the keyboard lands on whichever tab happens to be last.
  void closeTabs(
    Iterable<String> ids, {
    bool detach = true,
    String? activate,
  }) {
    final closing = {
      for (final id in ids)
        if (_tabById(id) != null) id,
    };
    if (closing.isEmpty) return;
    _userClosedSinceRestore = true;
    for (final id in closing) {
      for (final paneId in _tabById(id)!.layout.panes) {
        if (detach) {
          _detachOrRelease(paneId);
        } else {
          _releasePane(paneId);
        }
      }
    }
    _tabs.removeWhere((t) => closing.contains(t.id));
    _tabsMutated();
    if (closing.contains(_activeTabId)) {
      _activeTabId =
          _tabById(activate)?.id ??
          _survivorInFocusedGroup(closing) ??
          (_tabs.isEmpty ? null : _tabs.last.id);
    }
    _publish();
    persistStructure();
    // Closing the active tab hands the keyboard to whichever tab took its
    // place, rather than leaving it nowhere.
    _focusActivePane();
  }

  TerminalTab? _tabById(String? id) {
    if (id == null) return null;
    final index = _tabIndex[id];
    return index == null ? null : _tabs[index];
  }

  TerminalTab? _tabContaining(String paneId) => _tabById(_paneOwner[paneId]);

  /// Puts [paneId] on screen wherever it currently lives: focused in the tab
  /// that holds it, or — for one in the background list — back in a tab of its
  /// own. Returns that tab's id.
  String _showPane(String paneId) {
    final tab = _tabContaining(paneId);
    if (tab != null) {
      focusPane(paneId);
      return tab.id;
    }
    _detached.removeWhere((s) => s.paneId == paneId);
    _detachedMutated();
    final tabId = _newTabFor(paneId);
    _publish();
    _focusActivePane();
    return tabId;
  }

  /// Adds a tab holding [paneId] on its own and makes it the active one.
  String _newTabFor(String paneId) {
    final tabId = _newId();
    _tabs.add(
      TerminalTab(
        id: tabId,
        layout: PaneLayout.single(paneId),
        focusedPaneId: paneId,
      ),
    );
    _tabsMutated();
    _activeTabId = tabId;
    return tabId;
  }

  void _replaceTab(TerminalTab updated) {
    final index = _tabIndex[updated.id];
    if (index == null) return;
    _tabs[index] = updated;
    _tabsMutated();
    _publish();
  }

  void _stepTab(int by) {
    if (_tabs.length < 2) return;
    final index = _tabIndex[_activeTabId];
    if (index == null) return;
    activateTab(_tabs[(index + by + _tabs.length) % _tabs.length].id);
  }

  void nextTab() => _stepTab(1);

  void previousTab() => _stepTab(-1);
}
