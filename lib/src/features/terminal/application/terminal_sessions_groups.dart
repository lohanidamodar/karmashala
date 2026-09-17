part of 'terminal_sessions_controller.dart';

// `Notifier.ref` is `@protected`, which covers a subclass and not an extension
// splitting that subclass's own body inside its own library.
// ignore_for_file: invalid_use_of_protected_member

/// The **workspace groups**: a group is a tab strip, a surface and a status bar
/// — the unit a split makes. The tree itself is `WorkspaceLayout`, which is
/// pure; here is everything that also has to touch `_tabs` and publish.
extension TerminalWorkspaceGroups on TerminalSessionsController {
  /// The group the keyboard is in, or null before anything is open.
  WorkspaceGroup? get _focusedGroup =>
      _workspace?.groupById(_focusedGroupId ?? '');

  /// Whether [group] is room the user cleared and has not filled yet.
  bool _isEmptyGroup(WorkspaceGroup group) =>
      group.panes.length == 1 && isEmptyGroupSlot(group.panes.first);

  /// Whether group [groupId] is still empty.
  bool isEmptyGroup(String groupId) {
    final group = _workspace?.groupById(groupId);
    return group != null && _isEmptyGroup(group);
  }

  /// The tabs in group [groupId], in the order its strip shows them.
  List<TerminalTab> tabsInGroup(String groupId) {
    final group = _workspace?.groupById(groupId);
    if (group == null) return const [];
    return [
      for (final id in group.panes) ?_tabById(id),
    ];
  }

  /// The tab group [groupId] is showing, or null while it is empty.
  String? activeTabInGroup(String groupId) {
    final group = _workspace?.groupById(groupId);
    if (group == null || _isEmptyGroup(group)) return null;
    return group.activePaneId;
  }

  /// Divides the focused group — empty or not — along [axis], leaving the new
  /// group **empty** and focused. Null when it is too small: [canSplitWorkspace].
  String? splitWorkspace(SplitAxis axis) {
    final tree = _workspace;
    final group = _focusedGroup;
    if (tree == null || group == null || !canSplitWorkspace(axis)) return null;

    final slot = emptyGroupSlotId(_newId());
    final next = tree.split(group.activePaneId, axis, slot, _newId());
    _workspace = next;
    _focusedGroupId = next.groupOf(slot)?.id;
    _activeTabId = null;
    _publish();
    persistStructure();
    return _focusedGroupId;
  }

  /// Gives the keyboard to group [groupId] and to the tab it is showing.
  void focusGroup(String groupId) {
    if (_focusedGroupId == groupId) return;
    final group = _workspace?.groupById(groupId);
    if (group == null) return;
    _focusedGroupId = groupId;
    _activeTabId = _isEmptyGroup(group) ? null : group.activePaneId;
    _publish();
    _focusActivePane();
  }

  /// Moves the keyboard to the group next to the focused one in [direction],
  /// answered off the tree's geometry: the id [PaneLayout.paneInDirection]
  /// hands back is a tab, so the group holding it is the one on that side.
  bool moveGroupFocus(PaneDirection direction) {
    final tree = _workspace;
    final group = _focusedGroup;
    if (tree == null || group == null) return false;
    final landed = tree.paneInDirection(group.activePaneId, direction);
    final target = landed == null ? null : tree.groupOf(landed);
    if (target == null || target.id == group.id) return false;
    focusGroup(target.id);
    return true;
  }

  /// Whether [tabId] could be dropped on group [groupId]'s strip. A tab already
  /// there is refused — its position along the strip is [reorderTab]'s business.
  bool canMoveTabToGroup(String tabId, String groupId) {
    final group = _workspace?.groupById(groupId);
    return group != null &&
        _tabById(tabId) != null &&
        !group.panes.contains(tabId);
  }

  /// Moves [tabId] into group [groupId], at [index] along its strip when given.
  /// Nothing is closed, detached or relaunched — only which strip it hangs in
  /// changes; the group it leaves collapses if that was its last tab.
  bool moveTabToGroup(String tabId, String groupId, {int? index}) {
    if (!canMoveTabToGroup(tabId, groupId)) return false;
    final tree = _workspace!;
    final anchor = tree.groupById(groupId)!.activePaneId;
    final without = tree.close(tabId);
    // Only reachable if the tab was the last thing in the tree, and then the
    // target group could not have existed to move it into.
    if (without == null) return false;

    // The group keeps its id: filling a group is not making a new one, and the
    // strip, the bar and the element are all addressed by that id.
    final landed = isEmptyGroupSlot(anchor)
        ? without.replaceRegion(anchor, PaneGroup(groupId, panes: [tabId]))
        : without.addPane(anchor, tabId);
    _workspace = index == null ? landed : landed.reorderInGroup(tabId, index);
    _activeTabId = tabId;
    _publish();
    persistStructure();
    _focusActivePane();
    return true;
  }

  /// Whether [tabId] could be dropped on an edge of group [groupId] to make a
  /// new group beside it.
  bool canMoveTabBesideGroup(String tabId, String groupId) {
    final group = _workspace?.groupById(groupId);
    if (group == null || _tabById(tabId) == null) return false;
    // A group made only of the tab leaving it is the group it left, one
    // divider later.
    return !(group.panes.length == 1 && group.panes.first == tabId);
  }

  /// Divides group [groupId] along [axis] and puts [tabId] in the new group. A
  /// tab needs a group to host it, so it never lands in a bare region; a pane can.
  bool moveTabBesideGroup(
    String tabId,
    String groupId,
    SplitAxis axis, {
    bool insertBefore = false,
  }) {
    if (!canMoveTabBesideGroup(tabId, groupId)) return false;
    final tree = _workspace!;
    final without = tree.close(tabId);
    // Unreachable: the tab cannot be the only thing in the tree and still leave
    // a group behind to divide.
    if (without == null) return false;
    final anchor = without.groupById(groupId)?.activePaneId;
    if (anchor == null) return false;

    _workspace = without.splitWithNode(
      anchor,
      axis,
      PaneGroup(_newId(), panes: [tabId]),
      _newId(),
      insertBefore: insertBefore,
    );
    _activeTabId = tabId;
    _publish();
    persistStructure();
    _focusActivePane();
    return true;
  }

  /// Closes group [groupId] — its tabs with it — leaving the split it was in
  /// to collapse. Refuses to close the only group there is.
  bool closeGroup(String groupId, {bool detach = true}) {
    final tree = _workspace;
    final group = tree?.groupById(groupId);
    if (tree == null || group == null || tree.groups.length < 2) return false;

    if (!_isEmptyGroup(group)) {
      // The tabs are what the group is: taking them out empties it, and
      // reconciliation collapses what is left.
      closeTabs(List.of(group.panes), detach: detach);
      return true;
    }
    final next = tree.withoutMissing({
      for (final id in tree.panes)
        if (!group.panes.contains(id)) id,
    });
    if (next == null) return false;
    _workspace = next;
    if (_focusedGroupId == groupId) {
      // The group before it in the tree is the one it was split from; "the
      // first group" would throw the keyboard across a window of empty rooms.
      final index = tree.groups.indexOf(group);
      final heir = tree.groups[index > 0 ? index - 1 : 1];
      _focusedGroupId = heir.id;
      _activeTabId = _isEmptyGroup(heir) ? null : heir.activePaneId;
    }
    _publish();
    persistStructure();
    _focusActivePane();
    return true;
  }

  /// Moves [delta] — a share of the split's own extent — from child
  /// `index + 1` to child [index] of workspace split [splitId].
  void resizeWorkspace(String splitId, int index, double delta) {
    final tree = _workspace;
    if (tree == null) return;
    final next = tree.resize(splitId, index, delta);
    if (identical(next, tree)) return;
    _workspace = next;
    _publish();
  }

  /// A tab left in the focused group once [closing] has gone. Closing a tab
  /// must not hand the keyboard to whichever group holds the last tab in the
  /// window; it stays where the user was working.
  String? _survivorInFocusedGroup(Set<String> closing) {
    final group = _focusedGroup;
    if (group == null) return null;
    for (final id in group.panes) {
      if (!closing.contains(id) && !isEmptyGroupSlot(id)) return id;
    }
    return null;
  }

  /// Brings the workspace tree back in step with [_tabs], so a dozen tab verbs
  /// need know nothing about groups. Replaced only when it actually changed.
  void _reconcileWorkspace() {
    final live = {for (final tab in _tabs) tab.id};
    var tree = _workspace;

    if (tree != null) {
      final keep = {
        for (final id in tree.panes)
          if (live.contains(id) || isEmptyGroupSlot(id)) id,
      };
      if (keep.length != tree.panes.length) {
        tree = keep.isEmpty ? null : tree.withoutMissing(keep);
      }
    }
    for (final tab in _tabs) {
      if (tree != null && tree.contains(tab.id)) continue;
      tree = _withTabPlaced(tree, tab.id);
    }
    if (!identical(tree, _workspace)) _workspace = tree;
    _repairFocusedGroup();
    _syncTabOrder();
    // A collapsed group takes its face with it, or the map grows by one entry
    // per split for the life of the app.
    ref
        .read(terminalFacesProvider.notifier)
        .forget({for (final group in _workspace?.groups ?? const []) group.id});
  }

  /// [tree] with [tabId] in the focused group — filling the empty room a split
  /// cleared, or joining its strip.
  WorkspaceLayout _withTabPlaced(WorkspaceLayout? tree, String tabId) {
    if (tree == null) return PaneLayout.single(tabId);
    final group = tree.groupById(_focusedGroupId ?? '') ?? tree.groups.last;
    final anchor = group.activePaneId;
    // Its own id, not a fresh one: see [moveTabToGroup].
    return _isEmptyGroup(group)
        ? tree.replaceRegion(anchor, PaneGroup(group.id, panes: [tabId]))
        : tree.addPane(anchor, tabId);
  }

  /// Restores the invariant tying [_activeTabId], [_focusedGroupId] and the
  /// tree: the active tab is the focused group's, and null exactly when that
  /// group is empty.
  void _repairFocusedGroup() {
    final tree = _workspace;
    if (tree == null) {
      _focusedGroupId = null;
      return;
    }
    final active = _activeTabId;
    if (active != null && tree.contains(active)) {
      if (tree.groupOf(active)!.activePaneId != active) {
        _workspace = tree.activate(active);
      }
      _focusedGroupId = _workspace!.groupOf(active)!.id;
      return;
    }
    final focused = tree.groupById(_focusedGroupId ?? '') ?? tree.groups.first;
    _focusedGroupId = focused.id;
    _activeTabId = _isEmptyGroup(focused) ? null : focused.activePaneId;
  }

  /// Re-orders [_tabs] to follow the tree, so "the tabs, left to right" means
  /// the same thing to a strip, to a bulk close and to the store's ordinals.
  void _syncTabOrder() {
    final tree = _workspace;
    if (tree == null || _tabs.length < 2) return;
    final order = <String, int>{};
    for (final (index, id) in tree.panes.indexed) {
      order[id] = index;
    }
    const last = 1 << 30;
    final sorted = [..._tabs]
      ..sort((a, b) => (order[a.id] ?? last).compareTo(order[b.id] ?? last));
    for (var i = 0; i < sorted.length; i++) {
      if (identical(sorted[i], _tabs[i])) continue;
      _tabs
        ..clear()
        ..addAll(sorted);
      _tabsMutated();
      return;
    }
  }
}
