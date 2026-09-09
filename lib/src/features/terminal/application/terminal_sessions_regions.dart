part of 'terminal_sessions_controller.dart';

// `Notifier.ref` is `@protected`, which covers a subclass and not an
// extension — even one splitting that subclass's own body inside its own
// library, which is all any part of this file is.
// ignore_for_file: invalid_use_of_protected_member

/// The **regions inside one tab**: dividing a pane, the empty room a split
/// leaves, filling it, dragging a pane between regions and out into a tab of
/// its own — and which face the group holding a pane is showing.
///
/// The invariant the whole file rests on is stated once, on [isEmptySlot]: a
/// pane id a layout holds and `_instances` does not is an empty region.
extension TerminalPaneRegions on TerminalSessionsController {
  /// Divides the active tab's focused pane along [axis], leaving the new region
  /// **empty**, and focuses it. Returns the new region's pane id, or `null`
  /// when there is no tab, or the focused pane is itself an empty region.
  ///
  /// **A split starts nothing.** It used to launch a shell into the new half,
  /// which made "I want to see two things at once" cost a process nobody asked
  /// for and, worse, read as though the session being split had been forked.
  /// The report: *"when splitting the middle workspace, don't automatically
  /// start a terminal ... just create empty split where i can drag and move
  /// existing tabs or create new tabs"*. So a split divides space, the pane it
  /// divided carries on exactly as it was, and the user says what goes in the
  /// room — [openInSlot] for a new terminal, [moveTabIntoSlot] for one that
  /// already exists.
  ///
  /// The empty region is an ordinary leaf in the layout with no instance behind
  /// it; see [isEmptySlot] for the invariant that makes that legible.
  String? splitPane(SplitAxis axis) {
    final tab = _activeTab;
    if (tab == null) return null;
    // Nothing to divide: an empty region cut in two is two empty regions, and
    // a window can grow those without limit.
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

  /// Whether [paneId] is a region of a split with nothing in it yet.
  ///
  /// **The invariant, stated once:** a pane id that a layout holds and
  /// [_instances] does not is an empty region. Every other pane in a layout has
  /// an instance, because creating one and adopting it is a single statement —
  /// so "in a tab, no instance" cannot mean anything else, and no parallel set
  /// of slot ids has to be kept in step with the layout.
  bool isEmptySlot(String paneId) =>
      _isEmptyRegion(paneId) && _tabContaining(paneId) != null;

  /// [isEmptySlot] without the tab lookup, for callers that already hold the
  /// tab.
  ///
  /// A **document** is the one other pane a layout holds and [_instances] does
  /// not, and it is the opposite of empty — it is a surface the workbench
  /// draws itself. See [isDocumentPane].
  bool _isEmptyRegion(String paneId) =>
      !_instances.containsKey(paneId) && !isDocumentPane(paneId);

  /// The first empty region of the active tab, if it has one.
  ///
  /// What the command palette offers to move a tab into, so the drag has an
  /// equivalent that never needs a mouse.
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
  /// not whichever one has focus.
  ///
  /// Every caller that has a pane in hand should come through here: "show the
  /// terminal" from a launch, a reveal or an approval means the group the pane
  /// landed in, and pointing it at the focused group would look correct with
  /// one group and move the wrong one with two. A pane in no group falls back
  /// to the focused one, which is the only honest answer left.
  void showTerminalForPane(String paneId) =>
      _showFace(groupOfPane(paneId) ?? _focusedGroupId, terminal: true);

  /// Shows the terminal face of the group whose strip holds [tabId].
  void showTerminalForTab(String tabId) =>
      _showFace(groupOfTab(tabId) ?? _focusedGroupId, terminal: true);

  /// Shows the terminal face of the focused group — for a command that names
  /// no pane, such as opening a shell or the palette's *Terminal view*.
  void showTerminalHere() => _showFace(_focusedGroupId, terminal: true);

  /// Shows the **conversation** face of the group holding [paneId] — the exact
  /// mirror of [showTerminalForPane], including its rule about *which* group.
  ///
  /// It exists because the composer *is* the conversation: `bb4283f0` stopped
  /// the workbench mounting a session's transcript until it had been asked
  /// for, so text queued for a composer nobody had opened went nowhere
  /// visible. This is how a caller asks.
  ///
  /// **For text arriving from somewhere the user is not** — a picture sent
  /// from the phone, which is `remote_bindings`' only caller. Notes and todos
  /// used to call it too and no longer do: the user is right there, so they
  /// follow the face already showing rather than turning it. See
  /// `offerToSession`.
  ///
  /// **A pane is required, unlike [showTerminalHere].** "Reveal this session's
  /// conversation" has no sensible answer for a session running in no pane:
  /// falling back to the focused group would open whichever *other* session
  /// that group holds, so text offered to A would flip a group showing B into
  /// B's chat. Callers check for a pane first.
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

  /// The empty **workspace group**, if the user has cleared one — what the
  /// palette offers to move a tab into.
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

  /// The focused pane, when it is one that could be pulled out of its split
  /// into a tab of its own — what the command palette offers as the way back.
  String? paneMovableToNewTab() {
    final tab = _activeTab;
    if (tab == null || _occupiedPanes(tab) < 2) return null;
    return _isEmptyRegion(tab.focusedPaneId) ? null : tab.focusedPaneId;
  }

  /// Starts [profile] in the empty region [slotPaneId] and focuses it. Returns
  /// the new pane's id, or `null` when that is not an empty region.
  ///
  /// The region's own id is retired rather than reused: an empty region is not
  /// the terminal that later occupies it, and swapping the leaf is what makes
  /// filling one a *layout* change the pane stack can see.
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

  /// Whether [paneId] could be moved into the region holding [targetPaneId].
  ///
  /// The pane-sized counterpart of [canMoveTabIntoSlot], asked by a region
  /// header before it lights up. A pane cannot be moved into the region it is
  /// already in, and an empty region is room rather than a pane, so it is
  /// nothing to pick up.
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

  /// Moves one pane out of its region and into the one holding [targetPaneId],
  /// bringing it to the front there. Returns whether it moved.
  ///
  /// The region it leaves collapses when it was the last pane in it — the same
  /// rule [closePane] applies, and the reason a region can be emptied by a drag
  /// without leaving a hole behind. Nothing is detached or relaunched: the
  /// session is the same object at a new address.
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
      // Re-read: removing the pane may have taken the source tab out of the
      // list, which moves every index after it.
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

  /// [layout] with [paneId] put into the region holding [targetPaneId].
  ///
  /// An **empty** region is replaced rather than added to, which retires the id
  /// it was standing in for — the same swap [openInSlot] makes, and for the
  /// same reason: a region is not the terminal that comes to occupy it.
  PaneLayout _placedInto(
    PaneLayout layout,
    String targetPaneId,
    String paneId,
  ) => _isEmptyRegion(targetPaneId)
      ? layout.replaceRegion(targetPaneId, PaneGroup.of(paneId))
      : layout.addPane(targetPaneId, paneId);

  /// Removes [paneId] from [tab] without touching the pane itself, dropping the
  /// tab when nothing worth coming back to is left in it.
  ///
  /// Shared by [movePaneIntoRegion] and [movePaneToNewTab]: both take a pane
  /// out of a tab and put it somewhere else, and the question of what the tab
  /// it left should look like has one answer.
  void _takePaneOutOfTab(TerminalTab tab, String paneId) {
    final layout = tab.layout.close(paneId);
    if (layout == null || layout.panes.every(_isEmptyRegion)) {
      // A tab holding nothing but empty regions is not a tab — there is
      // nothing in it and nothing to come back to. Removed directly rather
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

  /// Which pane should hold the keyboard in [tab] once its layout became
  /// [next].
  ///
  /// The focused pane usually survives. When it does not, the keyboard stays in
  /// the *region* it was in if that region is still there — closing one tab of
  /// a stack must not throw focus across the window — and otherwise falls to
  /// the first pane actually on screen.
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

  /// One pane id per region of the active tab other than the one [paneId] is
  /// in — what the palette offers as somewhere to move a pane to.
  ///
  /// Named by a pane rather than by a region id because that is how every move
  /// verb is addressed; the caller has a pane in hand, not a tree node.
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

  /// Pulls [paneId] out of the split it is in and gives it a tab of its own —
  /// the way back out, and the reverse of [moveTabIntoSlot]. Returns the new
  /// tab's id, or `null` when the pane is not in a split.
  ///
  /// The region it vacates goes with it and the split collapses, which is what
  /// VS Code does to an emptied group and what [shouldCollapseOnExit] already
  /// says about a split whose content has gone: a split is a working surface,
  /// and one side of it holding nothing is not a surface anyone asked for.
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
