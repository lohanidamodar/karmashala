part of 'terminal_sessions_controller.dart';

// `Notifier.ref` is `@protected`, which covers a subclass and not an extension
// splitting that subclass's own body inside its own library.
// ignore_for_file: invalid_use_of_protected_member

/// Opening, activating, re-ordering and closing **tabs**. See
/// `terminal_sessions_groups.dart` for the tree these tabs hang in.
extension TerminalTabVerbs on TerminalSessionsController {
  /// Opens a new tab running [profile] and makes it active. Returns its id.
  String openTab(
    TerminalProfile profile, {
    String? workingDirectory,
    String? adoptPaneId,
  }) {
    final tabId = _newId();
    final paneId = _createPane(
      profile,
      workingDirectory: workingDirectory,
      adoptPaneId: adoptPaneId,
    );
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

  /// Opens the Settings tab, or brings the open one forward: it is one document
  /// over one store, so a second tab would be the same page disagreeing.
  String openSettingsTab() {
    final open = _tabContaining(kSettingsPaneId);
    if (open != null) {
      activateTab(open.id);
      return open.id;
    }
    final tabId = _newId();
    _tabs.add(
      TerminalTab(
        id: tabId,
        layout: PaneLayout.single(kSettingsPaneId),
        focusedPaneId: kSettingsPaneId,
      ),
    );
    _tabsMutated();
    _activeTabId = tabId;
    _publish();
    persistStructure();
    return tabId;
  }

  /// Opens a new tab running an agent CLI in a PTY and makes it active. The
  /// pane is an ordinary terminal, which is what makes any registry agent usable
  /// without a protocol adapter.
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

  /// Opens an agent session in an empty split region without creating a tab;
  /// null when [slotPaneId] is stale or occupied. The pane comes after the check.
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
        // Unused for an agent pane, but the factory requires one and a bogus
        // profile would be worse than the host default.
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
  /// Waiting for the tab to be opened is what keeps it cheap.
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
      // The Start button's own path, so opening a tab and pressing Start do the
      // same thing, scrollback included.
      startPane(paneId);
    }
  }

  /// Moves tab [tabId] to [toIndex] and returns whether anything moved. It does
  /// not activate it: [activateTab] restarts panes, and tidying must not spawn.
  bool reorderTab(String tabId, int toIndex) {
    // Within its own group: [toIndex] is a position in the strip the chip was
    // dragged along, and every group has a strip of its own.
    final tree = _workspace;
    if (tree == null || _tabById(tabId) == null) return false;
    final next = tree.reorderInGroup(tabId, toIndex);
    if (identical(next, tree)) return false;
    _workspace = next;
    _publish();
    persistStructure();
    return true;
  }

  /// Closes tab [id]. A *view* action, so a pane with a running process is
  /// detached rather than killed unless `detach: false` — which is what "End
  /// session" passes.
  void closeTab(String id, {bool detach = true}) =>
      closeTabs([id], detach: detach);

  /// Closes every tab in [ids] at once — one publish and one save whatever the
  /// count. [activate] names the tab to leave in front if the active one goes.
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
          // Where the user was before this tab, not the first one in the strip.
          _mostRecentSurvivor(closing) ??
          _survivorInFocusedGroup(closing) ??
          (_tabs.isEmpty ? null : _tabs.last.id);
    }
    _publish();
    persistStructure();
    // Hands the keyboard to whichever tab took the closed one's place, rather
    // than leaving it nowhere.
    _focusActivePane();
  }

  TerminalTab? _tabById(String? id) {
    if (id == null) return null;
    final index = _tabIndex[id];
    return index == null ? null : _tabs[index];
  }

  TerminalTab? _tabContaining(String paneId) => _tabById(_paneOwner[paneId]);

  /// Puts [paneId] on screen wherever it lives: focused in its own tab, or —
  /// for one in the background list — back in a tab of its own.
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
