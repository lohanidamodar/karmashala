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

  /// [openTab], with [text] typed at the new shell's prompt and **left there**:
  /// nothing here presses Enter. False when the pane cannot take text before it
  /// is connected — the caller still has the command to show.
  ({String tabId, bool typed}) openTabTyping(
    TerminalProfile profile,
    String text, {
    String? workingDirectory,
  }) {
    final tabId = openTab(profile, workingDirectory: workingDirectory);
    final paneId = _tabById(tabId)?.focusedPaneId;
    final instance = paneId == null ? null : instanceFor(paneId);
    if (instance is! PromptTypingTerminalInstance) {
      return (tabId: tabId, typed: false);
    }
    (instance as PromptTypingTerminalInstance).typeAtPrompt(text);
    return (tabId: tabId, typed: true);
  }

  /// Opens document pane [paneId] in a tab, or brings the open one forward:
  /// one tab per document, or two views would disagree about the same thing.
  String openDocumentTab(String paneId) {
    final open = _tabContaining(paneId);
    if (open != null) {
      activateTab(open.id);
      return open.id;
    }
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
    _publish();
    persistStructure();
    return tabId;
  }

  /// Opens a tab attached to a session the server hosts — [paneId] names it
  /// session (`hostedRunSessionId`) — or brings the open one forward. The
  /// pane never starts a process of its own. Null when this machine's server
  /// is not reachable for panes.
  String? openHostedRunTab({required String paneId, required String title}) {
    final open = _tabContaining(paneId);
    if (open != null) {
      activateTab(open.id);
      return open.id;
    }
    final instance = ref.read(hostedRunPaneFactoryProvider)(
      id: paneId,
      title: title,
    );
    if (instance == null) return null;
    _adopt(paneId, instance);
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
    _publish();
    persistStructure();
    return tabId;
  }

  /// Settings is one document over one store, so a second tab would be the
  /// same page disagreeing with itself.
  String openSettingsTab() => openDocumentTab(kSettingsPaneId);

  /// Usage is one view over every account, so, like Settings, one tab.
  String openUsageTab() => openDocumentTab(kUsagePaneId);

  /// Stores is one view over every app, so, like Usage, one tab.
  String openStoresTab() => openDocumentTab(kStoresPaneId);

  /// Opens [hostPath] in an editor tab: one tab per file, or two buffers would
  /// disagree about the same bytes.
  String openEditorTab(String hostPath) =>
      openDocumentTab(editorPaneId(hostPath));

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
      // Re-attached to what the server still holds; the Start button is what
      // asks it for a new one.
      _attachRestored(paneId);
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
  void closeTabs(Iterable<String> ids, {bool detach = true, String? activate}) {
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
          // "End session": the hosted session goes too, not just the view.
          _ending.add(paneId);
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

  /// Puts [paneId] on screen wherever it lives: focused in its own tab, or
  /// — for one with no tab — in a tab of its own.
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
