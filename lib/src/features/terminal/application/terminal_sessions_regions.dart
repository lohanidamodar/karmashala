part of 'terminal_sessions_controller.dart';

// `Notifier.ref` is `@protected`, which covers a subclass and not an extension
// splitting that subclass's own body inside its own library.
// ignore_for_file: invalid_use_of_protected_member

/// The **regions inside one tab**: dividing a pane, filling the empty room a
/// split leaves, dragging panes about — and which face a group is showing. The
/// invariant it all rests on is stated once, on [isEmptySlot].
extension TerminalPaneRegions on TerminalSessionsController {
  /// Divides the active tab's focused pane along [axis], leaving the new region
  /// **empty** — a split starts nothing. Null when there is nothing to divide.
  String? splitPane(SplitAxis axis) {
    final tab = _activeTab;
    if (tab == null) return null;
    // An empty region cut in two is two empty regions, without limit.
    if (_isEmptyRegion(tab.focusedPaneId)) return null;

    final slotId = _newId();
    _replaceTab(
      tab.copyWith(
        layout: tab.layout.split(tab.focusedPaneId, axis, slotId, _newId()),
        focusedPaneId: slotId,
      ),
    );
    _focusActivePane();
    persistStructure();
    return slotId;
  }

  /// Whether [paneId] is a region of a split with nothing in it yet. A pane id a
  /// layout holds and [_instances] does not *is* an empty region.
  bool isEmptySlot(String paneId) =>
      _isEmptyRegion(paneId) && _tabContaining(paneId) != null;

  /// [isEmptySlot] without the tab lookup. A **document** is the one other pane
  /// a layout holds and [_instances] does not, and it is the opposite of empty.
  bool _isEmptyRegion(String paneId) =>
      !_instances.containsKey(paneId) && !isDocumentPane(paneId);

  /// The first empty region of the active tab — what the palette offers to move
  /// a tab into, so the drag has a keyboard equivalent.
  String? emptySlotInActiveTab() {
    final tab = _activeTab;
    if (tab == null) return null;
    for (final paneId in tab.layout.panes) {
      if (_isEmptyRegion(paneId)) return paneId;
    }
    return null;
  }

  /// The workspace group whose strip holds the tab [paneId] is in.
  String? groupOfPane(String paneId) {
    final tab = _tabContaining(paneId);
    if (tab == null) return null;
    return _workspace?.groupOf(tab.id)?.id;
  }

  /// The workspace group whose strip holds [tabId].
  String? groupOfTab(String tabId) => _workspace?.groupOf(tabId)?.id;

  /// Shows the terminal face of the group holding [paneId] — **that** group,
  /// not whichever has focus, which would look right with one group and move
  /// the wrong one with two. A pane in no group falls back to the focused one.
  void showTerminalForPane(String paneId) =>
      _showFace(groupOfPane(paneId) ?? _focusedGroupId, terminal: true);

  /// Shows the terminal face of the group whose strip holds [tabId].
  void showTerminalForTab(String tabId) =>
      _showFace(groupOfTab(tabId) ?? _focusedGroupId, terminal: true);

  /// Shows the terminal face of the focused group — for a command that names
  /// no pane, such as opening a shell or the palette's *Terminal view*.
  void showTerminalHere() => _showFace(_focusedGroupId, terminal: true);

  /// The mirror of [showTerminalForPane]. **A pane is required**: falling back
  /// to the focused group would flip a group showing B into B's chat.
  void revealConversationForPane(String paneId) =>
      _showFace(groupOfPane(paneId) ?? _focusedGroupId, terminal: false);

  /// Shows group [groupId]'s terminal or its conversation.
  void showFaceIn(String groupId, {required bool terminal}) =>
      _showFace(groupId, terminal: terminal);

  /// Swaps the focused group's face — what `` Ctrl+` `` does.
  void toggleFaceHere() {
    final group = _focusedGroupId;
    if (group == null) return;
    ref.read(terminalFacesProvider.notifier).toggle(group);
  }

  void _showFace(String? groupId, {required bool terminal}) {
    if (groupId == null) return;
    ref.read(terminalFacesProvider.notifier).show(groupId, terminal: terminal);
  }

  /// The empty **workspace group**, if the user has cleared one.
  String? emptyWorkspaceGroup() {
    for (final group in _workspace?.groups ?? const <WorkspaceGroup>[]) {
      if (_isEmptyGroup(group)) return group.id;
    }
    return null;
  }

  /// Whether there is a focused group with a tab in it to divide.
  bool canSplitWorkspace() {
    final group = _focusedGroup;
    return group != null && !_isEmptyGroup(group);
  }

  /// Whether the focused pane could be divided inside its own tab.
  bool focusedPaneIsSplittable() {
    final tab = _activeTab;
    return tab != null && !_isEmptyRegion(tab.focusedPaneId);
  }

  /// The focused pane, when it could be pulled out of its split into a tab of
  /// its own.
  String? paneMovableToNewTab() {
    final tab = _activeTab;
    if (tab == null || _occupiedPanes(tab) < 2) return null;
    return _isEmptyRegion(tab.focusedPaneId) ? null : tab.focusedPaneId;
  }

  /// Starts [profile] in the empty region [slotPaneId] and focuses it; null
  /// when that is not an empty region. The region's id is retired rather than
  /// reused, which is what makes filling one a layout change the stack sees.
  String? openInSlot(
    String slotPaneId,
    TerminalProfile profile, {
    String? workingDirectory,
  }) {
    final tab = _tabContaining(slotPaneId);
    if (tab == null || !_isEmptyRegion(slotPaneId)) return null;

    final paneId = _createPane(profile, workingDirectory: workingDirectory);
    _replaceTab(
      tab.copyWith(
        layout: tab.layout.replaceRegion(slotPaneId, PaneGroup.of(paneId)),
        focusedPaneId: paneId,
      ),
    );
    _focusActivePane();
    persistStructure();
    return paneId;
  }

  /// Whether [sourcePaneId] can be dropped onto [targetPaneId] to split it.
  bool canSplitPaneWithPane(String targetPaneId, String sourcePaneId) {
    if (targetPaneId == sourcePaneId || _isEmptyRegion(sourcePaneId)) return false;
    final target = _tabContaining(targetPaneId);
    final source = _tabContaining(sourcePaneId);
    return target != null && source != null;
  }

  /// Splits the region holding [targetPaneId] with [sourcePaneId] along [axis].
  bool splitPaneWithPane(
    String targetPaneId,
    String sourcePaneId,
    SplitAxis axis, {
    bool insertBefore = false,
  }) {
    if (!canSplitPaneWithPane(targetPaneId, sourcePaneId)) return false;
    final target = _tabContaining(targetPaneId)!;
    final sourceTab = _tabContaining(sourcePaneId)!;

    if (sourceTab.id == target.id) {
      final closedLayout = target.layout.close(sourcePaneId);
      if (closedLayout == null) return false;
      final targetIndex = _tabIndex[target.id]!;
      final updatedLayout = closedLayout.splitWithNode(
        targetPaneId,
        axis,
        PaneGroup.of(sourcePaneId),
        _newId(),
        insertBefore: insertBefore,
      );
      _tabs[targetIndex] = target.copyWith(
        layout: updatedLayout.activate(sourcePaneId),
        focusedPaneId: sourcePaneId,
      );
    } else {
      final closedSource = sourceTab.layout.close(sourcePaneId);
      if (closedSource == null) {
        _tabs.removeWhere((t) => t.id == sourceTab.id);
      } else {
        final sourceIndex = _tabIndex[sourceTab.id]!;
        final newFocused = closedSource.visiblePanes.contains(sourceTab.focusedPaneId)
            ? sourceTab.focusedPaneId
            : closedSource.visiblePanes.first;
        _tabs[sourceIndex] = sourceTab.copyWith(
          layout: closedSource,
          focusedPaneId: newFocused,
        );
      }
      _tabsMutated();
      final targetIndex = _tabIndex[target.id]!;
      final updatedLayout = target.layout.splitWithNode(
        targetPaneId,
        axis,
        PaneGroup.of(sourcePaneId),
        _newId(),
        insertBefore: insertBefore,
      );
      _tabs[targetIndex] = target.copyWith(
        layout: updatedLayout.activate(sourcePaneId),
        focusedPaneId: sourcePaneId,
      );
    }
    _tabsMutated();
    _activeTabId = target.id;
    _publish();
    persistStructure();
    _focusActivePane();
    return true;
  }

  /// Whether [paneId] could be moved into the region holding [targetPaneId] —
  /// not its own region, and an empty region is room rather than a pane to pick
  /// up. Asked by a region header before it lights up.
  bool canMovePaneIntoRegion(String paneId, String targetPaneId) {
    if (_isEmptyRegion(paneId)) return false;
    final source = _tabContaining(paneId);
    final target = _tabContaining(targetPaneId);
    if (source == null || target == null) return false;
    final from = source.layout.groupOf(paneId);
    final to = target.layout.groupOf(targetPaneId);
    if (from == null || to == null) return false;
    return !identical(from, to);
  }

  /// Moves one pane into the region holding [targetPaneId], bringing it to the
  /// front there. The region it leaves collapses if it was the last pane in it;
  /// nothing is detached or relaunched — same object, new address.
  bool movePaneIntoRegion(String paneId, String targetPaneId) {
    if (!canMovePaneIntoRegion(paneId, targetPaneId)) return false;
    final source = _tabContaining(paneId)!;
    final target = _tabContaining(targetPaneId)!;

    if (source.id == target.id) {
      // Non-null: the pane and the target are in different regions, so the
      // target's region survives the close.
      final without = source.layout.close(paneId)!;
      _tabs[_tabIndex[source.id]!] = source.copyWith(
        layout: _placedInto(without, targetPaneId, paneId),
        focusedPaneId: paneId,
      );
      _tabsMutated();
    } else {
      _takePaneOutOfTab(source, paneId);
      // Re-read: removing the pane may have dropped the source tab, moving
      // every index after it.
      final host = _tabById(target.id);
      if (host == null) return false;
      _tabs[_tabIndex[host.id]!] = host.copyWith(
        layout: _placedInto(host.layout, targetPaneId, paneId),
        focusedPaneId: paneId,
      );
      _tabsMutated();
    }
    _activeTabId = target.id;
    _publish();
    persistStructure();
    _focusActivePane();
    return true;
  }

  /// [layout] with [paneId] put into the region holding [targetPaneId]. An
  /// **empty** region is replaced rather than added to, retiring the id it
  /// stood in for — the same swap [openInSlot] makes.
  PaneLayout _placedInto(
    PaneLayout layout,
    String targetPaneId,
    String paneId,
  ) => _isEmptyRegion(targetPaneId)
      ? layout.replaceRegion(targetPaneId, PaneGroup.of(paneId))
      : layout.addPane(targetPaneId, paneId);

  /// Removes [paneId] from [tab] without touching the pane itself, dropping the
  /// tab when nothing worth coming back to is left in it.
  void _takePaneOutOfTab(TerminalTab tab, String paneId) {
    final layout = tab.layout.close(paneId);
    if (layout == null || layout.panes.every(_isEmptyRegion)) {
      // Nothing in it and nothing to come back to. Removed directly rather
      // than through [closeTab]: there is no session in it to detach.
      _tabs.removeWhere((t) => t.id == tab.id);
    } else {
      _tabs[_tabIndex[tab.id]!] = tab.copyWith(
        layout: layout,
        focusedPaneId: _refocused(tab, layout),
      );
    }
    _tabsMutated();
  }

  /// Which pane holds the keyboard in [tab] once its layout became [next]. The
  /// keyboard stays in its region if that survives, else the first pane on screen.
  String _refocused(TerminalTab tab, PaneLayout next) {
    final focused = tab.focusedPaneId;
    if (next.contains(focused)) return focused;
    final region = tab.layout.groupOf(focused);
    if (region != null) {
      for (final group in next.groups) {
        if (group.id == region.id) return group.activePaneId;
      }
    }
    return next.visiblePanes.first;
  }

  /// One pane id per region of the active tab other than [paneId]'s. Named by a
  /// pane because that is how every move verb is addressed — the caller has a
  /// pane in hand, not a tree node.
  List<String> regionAnchorsBesides(String paneId) {
    final tab = _tabContaining(paneId);
    if (tab == null) return const [];
    final own = tab.layout.groupOf(paneId);
    return [
      for (final group in tab.layout.groups)
        if (!identical(group, own)) group.activePaneId,
    ];
  }

  /// Brings the next pane stacked in the focused region to the front. Does
  /// nothing in a region holding one pane.
  void nextPaneInRegion() => _stepPaneInRegion(1);

  void previousPaneInRegion() => _stepPaneInRegion(-1);

  void _stepPaneInRegion(int by) {
    final tab = _activeTab;
    if (tab == null) return;
    final group = tab.layout.groupOf(tab.focusedPaneId);
    if (group == null || group.panes.length < 2) return;
    final panes = group.panes;
    final index = panes.indexOf(tab.focusedPaneId);
    focusPane(panes[(index + by + panes.length) % panes.length]);
  }

  /// Pulls [paneId] out of its split into a tab of its own — the reverse of
  /// [moveTabIntoSlot]; null when the pane is not in a split. The region it
  /// vacates collapses with it, as [shouldCollapseOnExit] already says.
  String? movePaneToNewTab(String paneId) {
    final tab = _tabContaining(paneId);
    if (tab == null || tab.layout.panes.length < 2) return null;
    if (_isEmptyRegion(paneId)) return null;

    _takePaneOutOfTab(tab, paneId);
    final tabId = _newTabFor(paneId);
    _publish();
    persistStructure();
    _focusActivePane();
    return tabId;
  }
}
