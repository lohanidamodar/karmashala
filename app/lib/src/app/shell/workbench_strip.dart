part of 'workbench.dart';

/// One tab in the strip. The chip is a closure, not a widget: at a hundred tabs
/// the strip must build only the five or six on screen.
class _StripTab {
  const _StripTab({required this.active, required this.chip});

  final bool active;
  final Widget Function() chip;
}

/// The workbench tab strip — terminal tabs and nothing else. Overflow is
/// [TabPicker] rather than better scrolling; a strip is hopeless at a hundred.
class _TabStrip extends ConsumerWidget {
  const _TabStrip({required this.groupId, required this.groupFocused});

  /// The group whose tabs this strip shows. Null only before the window has a
  /// workspace, when the strip is empty by definition.
  final String? groupId;

  /// Whether the keyboard is in this group. Only the focused group's active
  /// chip draws as the one on screen.
  final bool groupFocused;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final tabs = _tabs(ref);
    final sessions = ref.read(terminalSessionsControllerProvider.notifier);
    final group = groupId;

    // The strip is where a pane goes to stop being in a split — the same verb
    // as the pane menu's "Move pane to a new tab" and the palette's.
    return DragTarget<TerminalDrag>(
      onWillAcceptWithDetails: (details) => switch (details.data) {
        PaneDrag(:final paneId) => sessions.isPaneInSplit(paneId),
        // A tab is already a tab, so there is nothing here for it to *become* —
        // but a tab from another group's strip lands in this one.
        TabDrag(:final tabId) =>
          group != null && sessions.canMoveTabToGroup(tabId, group),
      },
      onAcceptWithDetails: (details) {
        switch (details.data) {
          case PaneDrag(:final paneId):
            final tabId = sessions.movePaneToNewTab(paneId);
            // It becomes a tab of the group it was dropped on, not of whichever
            // group happened to have the keyboard.
            if (tabId != null && group != null) {
              sessions.moveTabToGroup(tabId, group);
            }
          case TabDrag(:final tabId):
            if (group != null) sessions.moveTabToGroup(tabId, group);
        }
      },
      builder: (context, candidate, _) => Container(
        height: Chrome.tabStrip,
        color: candidate.isEmpty
            ? SurfaceTones.of(context).chrome
            : StateLayers.subtle(scheme),
        child: Row(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => _TabRail(
                  tabs: tabs,
                  width: constraints.maxWidth,
                  activeIndex: tabs.indexWhere((tab) => tab.active),
                  // The toolbar's own verb: a second way to make a tab would be
                  // a second place to decide the profile and the directory.
                  onNewTab: () {
                    final terminal = TerminalActions(ref);
                    terminal.open(terminal.defaultProfile());
                  },
                  // The one place in the strip no chip can offer: the room
                  // after the last tab is how a tab is made last.
                  onMoveTabToEnd: (tabId) {
                    // From another group it is a move; from this one it is an
                    // order along the same strip.
                    if (group != null &&
                        sessions.canMoveTabToGroup(tabId, group)) {
                      sessions.moveTabToGroup(tabId, group, index: tabs.length);
                    } else {
                      sessions.reorderTab(tabId, tabs.length - 1);
                    }
                  },
                ),
              ),
            ),
            // Nothing else. Every verb that used to sit here is in the title
            // bar now — seven repeated in a 286px group overflowed the bar.
            const SizedBox(width: Insets.xs),
          ],
        ),
      ),
    );
  }

  /// Every tab in the strip, left to right. Watched narrowly: the whole
  /// [TerminalSessionsState] republishes whenever any pane's process dies.
  List<_StripTab> _tabs(WidgetRef ref) {
    final group = groupId;
    final tabs = group == null
        ? const <TerminalTab>[]
        : ref.watch(workspaceGroupTabsProvider(group));
    final active = group == null
        ? null
        : ref.watch(workspaceGroupActiveTabProvider(group));
    final onPanes = _showingPanes(ref, groupId: group);
    return [
      for (final (index, tab) in tabs.indexed)
        _StripTab(
          active: onPanes && tab.id == active,
          chip: () => _TabChip(
            tab: tab,
            groupId: group,
            selected: onPanes && tab.id == active,
            // Selected says *this group is showing this tab*; accented says
            // *typing goes here*. Without it, four groups look equally selected.
            accented: groupFocused,
            index: index,
            tabCount: tabs.length,
          ),
        ),
    ];
  }
}

/// The part of the tab strip no chip covers, so a test can aim at it: named
/// rather than found by geometry, which would stop testing the rule.
const kTabStripEmptySpace = Key('tab-strip/empty-space');

/// The narrowest rail that can still draw both paging chevrons beside a tab:
/// one tab at its floor ([kMinTabWidth]) plus the two 30px icon buttons.
const double _chevronsFitFrom = kMinTabWidth + 60;

/// The scrolling part of the strip, and the affordances for what will not fit.
class _TabRail extends StatefulWidget {
  const _TabRail({
    required this.tabs,
    required this.width,
    required this.activeIndex,
    required this.onNewTab,
    required this.onMoveTabToEnd,
  });

  final List<_StripTab> tabs;

  /// The room the tabs have. A field rather than something read from the
  /// context, so a resize is a *prop change* the state can react to.
  final double width;

  final int activeIndex;

  /// Opens a terminal, for the gesture over the room the tabs did not use.
  final VoidCallback onNewTab;

  /// Sends a tab to the end of the strip, for a drop in that same room.
  final ValueChanged<String> onMoveTabToEnd;

  @override
  State<_TabRail> createState() => _TabRailState();
}

class _TabRailState extends State<_TabRail> {
  final _scroll = ScrollController();

  /// The strip's scroll position, and only while exactly one viewport owns it:
  /// for the frame the strip reshapes, two are attached and `single` throws.
  ScrollPosition? get _onePosition =>
      _scroll.positions.length == 1 ? _scroll.positions.first : null;

  @override
  void initState() {
    super.initState();
    // The controller has no position until the first layout, so neither the
    // reveal nor the chevrons can know anything until a frame has been drawn.
    _afterLayout();
  }

  @override
  void didUpdateWidget(_TabRail old) {
    super.didUpdateWidget(old);
    if (widget.activeIndex == old.activeIndex &&
        widget.width == old.width &&
        widget.tabs.length == old.tabs.length) {
      return;
    }
    _afterLayout();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Reveals the active tab and refreshes the chevrons once the frame has been
  /// laid out: until then the extents still describe the *previous* list.
  void _afterLayout() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(_revealActive);
    });
  }

  /// Scrolls the active tab into view — the one thing a plain scrolling row
  /// does not do, and why `Ctrl+PageUp`/`PageDown` were half-useless.
  void _revealActive() {
    final index = widget.activeIndex;
    final position = _onePosition;
    if (index < 0 || position == null) return;
    final extent = tabStripMetrics(widget.width, widget.tabs.length).extent;
    final target = revealOffset(
      position: position,
      leading: index * extent,
      extent: extent,
    );
    if (target != null) _scroll.jumpTo(target);
  }

  /// Scrolls most of a screenful, so a click lands somewhere recognisable
  /// rather than one tab along.
  void _page(bool forward) {
    final position = _onePosition;
    if (position == null) return;
    final step = position.viewportDimension * 0.8;
    final target = (position.pixels + (forward ? step : -step)).clamp(
      0.0,
      position.maxScrollExtent,
    );
    final duration = Motion.of(context).base;
    if (duration == Duration.zero) {
      _scroll.jumpTo(target);
    } else {
      _scroll.animateTo(target, duration: duration, curve: Motion.standard);
    }
  }

  @override
  Widget build(BuildContext context) {
    final metrics = tabStripMetrics(widget.width, widget.tabs.length);
    final list = ListView.builder(
      controller: _scroll,
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.zero,
      itemExtent: metrics.extent,
      itemCount: widget.tabs.length,
      itemBuilder: (context, index) => widget.tabs[index].chip(),
    );
    if (!metrics.overflowing) return _overEmptySpace(list, metrics.extent);
    // The chevrons go first when the rail runs out of room: below
    // [_chevronsFitFrom] that row needs ~100px and overflowed by 8.8px at 640.
    final chevrons = widget.width >= _chevronsFitFrom;
    return Row(
      children: [
        if (chevrons) _chevron(forward: false),
        Expanded(child: list),
        if (chevrons) _chevron(forward: true),
        _OverflowButton(count: widget.tabs.length),
      ],
    );
  }

  /// [list], with **double-click the empty space to open a tab** over the room
  /// the tabs did not use. A sibling: an ancestor would delay every chip click.
  Widget _overEmptySpace(Widget list, double extent) {
    final free = widget.width - extent * widget.tabs.length;
    // Half a pixel of slack: a rail whose tabs exactly fill it has no target,
    // and a zero-width one would be a control nobody can hit.
    if (free <= 0.5) return list;
    return Stack(
      children: [
        list,
        Positioned(
          key: kTabStripEmptySpace,
          left: widget.width - free,
          top: 0,
          bottom: 0,
          right: 0,
          // Two gestures over the same pixels, and they do not compete. A pane
          // is refused here so it carries on up to the strip's target.
          child: DragTarget<TerminalDrag>(
            onWillAcceptWithDetails: (details) => details.data is TabDrag,
            onAcceptWithDetails: (details) {
              if (details.data case TabDrag(:final tabId)) {
                widget.onMoveTabToEnd(tabId);
              }
            },
            builder: (context, candidate, _) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTap: widget.onNewTab,
              child: candidate.isEmpty
                  ? const SizedBox.expand()
                  // Against the last chip rather than the middle of the empty
                  // room: the tab lands immediately after the tabs.
                  : _markedForDrop(
                      context,
                      const SizedBox.expand(),
                      leading: true,
                    ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _chevron({required bool forward}) => ListenableBuilder(
    listenable: _scroll,
    builder: (context, _) {
      final position = _onePosition;
      // A position exists from the moment the controller is attached, but its
      // extents do not until layout, and `maxScrollExtent` throws before then.
      final can =
          position != null &&
          position.hasPixels &&
          position.hasContentDimensions &&
          (forward
              ? position.pixels < position.maxScrollExtent - 0.5
              : position.pixels > 0.5);
      // Shaped like the toolbar's buttons: chrome that acts on the strip.
      return IconButton(
        tooltip: forward ? 'Later tabs' : 'Earlier tabs',
        icon: Icon(
          forward ? AppIcons.caretRight : AppIcons.caretLeft,
          size: Chrome.icon,
        ),
        onPressed: can ? () => _page(forward) : null,
      );
    },
  );
}

/// The way to every tab the strip cannot show, and the only affordance here
/// that still works at a hundred.
class _OverflowButton extends ConsumerWidget {
  const _OverflowButton({required this.count});

  final int count;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Tooltip(
      // The name Narrator reads, so it has to say what the control *does*, not
      // only how many there are.
      message: 'All $count tabs — filter and switch',
      child: InkWell(
        onTap: () => TabPicker.show(context, terminalTabEntries),
        child: Container(
          height: Chrome.tabStrip,
          padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: SurfaceTones.of(context).line),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                AppIcons.listMagnifyingGlass,
                size: Chrome.icon,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: Insets.xs),
              Text(
                '$count',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
