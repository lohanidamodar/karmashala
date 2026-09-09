part of 'workbench.dart';

// The tab strip: the row itself, the scrolling rail inside it, and the way to
// every tab the rail cannot show.

/// One tab in the strip.
///
/// The chip is a closure, not a widget: at a hundred tabs the strip must build
/// only the five or six on screen, and a list of built chips would be exactly
/// the eager `ListView(children: [...])` the performance audit named.
class _StripTab {
  const _StripTab({required this.active, required this.chip});

  final bool active;
  final Widget Function() chip;
}

/// The workbench tab strip.
///
/// **What overflow is for.** The app is built for a hundred live terminals
///, and a horizontal strip is hopeless at a hundred
/// tabs however well it scrolls — so the answer to "I cannot reach my tabs"
/// cannot be better scrolling. It is [TabPicker]: a filterable list of every
/// tab, reached from a button that appears exactly when the strip stops being
/// enough. The chevrons either side are the answer to the *other* half of the
/// complaint — that reaching a tab two along needed a horizontal mouse wheel —
/// and they only earn their place while the overflow is mild.
///
/// **Only tabs.** A selected session used to get a conversation chip here as
/// well as a toggle in the same row, so one tap in the Explorer looked like two
/// things opening. Its controls live under the surface now (see [_SessionBar]);
/// this is terminal tabs and nothing else.
///
/// What is left beside them — the terminal's own toolbar with **new tab** in
/// it, focus mode — sits outside the scrolling region, so no number of tabs can
/// push the way to make another one off the end of the strip.
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

    // The strip is where a pane goes to stop being in a split. Dragging a pane
    // by its grip and dropping it here is the same verb as the pane menu's
    // "Move pane to a new tab" and the palette's — the gesture the whole
    // redesign turns on, because a drag that only goes one way leaves whatever
    // it moved stranded.
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
            ? scheme.surfaceContainerLow
            : scheme.primary.withValues(alpha: 0.08),
        child: Row(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => _TabRail(
                  tabs: tabs,
                  width: constraints.maxWidth,
                  activeIndex: tabs.indexWhere((tab) => tab.active),
                  // The toolbar's own verb, reached the way the toolbar reaches
                  // it. A second way to make a tab would be a second place for
                  // the default profile and the selected repository's directory
                  // to be decided.
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
            // Nothing else. Every verb that used to sit here — find, snippets,
            // the two splits, the new-terminal pair — asked no question a group
            // could answer that "the focused one" could not, and seven controls
            // repeated in a 286px group were the whole of why the bar below
            // overflowed. They are in the title bar now. See [ShellTitleBar].
            const SizedBox(width: Insets.xs),
          ],
        ),
      ),
    );
  }

  /// Every tab in the strip, left to right.
  ///
  /// **The shape of the strip, and nothing that happens inside a tab.** Watched
  /// narrowly on purpose: the whole [TerminalSessionsState] is republished
  /// whenever any pane's process dies, and at a hundred panes a process exiting
  /// is the common event — so watching it here rebuilt every chip in the strip
  /// for a dot that moved in one of them. Liveness is subscribed to per tab, by
  /// [_TabChip].
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
            // *and this is where typing goes*. Without the second, four groups
            // draw four fully selected tabs and nothing on screen says which
            // one your keystrokes reach.
            accented: groupFocused,
            index: index,
            tabCount: tabs.length,
          ),
        ),
    ];
  }
}

/// The part of the tab strip no chip covers, so a test can aim at it.
///
/// Named rather than found by geometry because "the empty space" is the whole
/// subject of the gesture: a test that computed the coordinate itself would
/// stop testing the rule the moment the rule changed.
const kTabStripEmptySpace = Key('tab-strip/empty-space');

/// The narrowest rail that can still draw both paging chevrons beside a tab.
///
/// One tab at its floor ([kMinTabWidth]) plus the two 30px icon buttons. Below
/// this the chevrons are dropped — see [_TabRailState.build].
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

  /// The room the tabs have, which decides how wide each draws and whether
  /// there is overflow at all. A field rather than something read from the
  /// context so a resize is a *prop change* the state can react to.
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

  /// The strip's scroll position, and only while exactly one viewport owns it.
  ///
  /// `hasClients` is not that question. It is true the moment *any* viewport is
  /// attached, and for one frame there are two: the strip changes shape when it
  /// starts overflowing — a bare `ListView` becomes a row with chevrons around
  /// it — which moves the list to a new slot, and the outgoing viewport does not
  /// detach until that frame ends. `ScrollController.position` is
  /// `positions.single`, so it threw `Bad state: Too many elements` out of the
  /// chevron's builder on every launch, which is where the strip first learns
  /// it has overflowed.
  ///
  /// Null for that frame means the chevrons are drawn disabled, which is what
  /// they already do before the first layout.
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

  /// Reveals the active tab and refreshes the chevrons once the frame this
  /// change belongs to has been laid out.
  ///
  /// Deferred for the reason quick open defers its own reveal: until the list
  /// has been laid out the scroll extents still describe the *previous* one,
  /// and clamping a target against those is how a strip ends up scrolled
  /// somewhere nobody asked for.
  void _afterLayout() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(_revealActive);
    });
  }

  /// Scrolls the active tab into view.
  ///
  /// The one thing a plain scrolling row does not do for itself, and the reason
  /// `Ctrl+PageUp`/`Ctrl+PageDown` were half-useless: stepping to a tab you
  /// cannot see is stepping to nowhere.
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
    _scroll.animateTo(
      (position.pixels + (forward ? step : -step)).clamp(
        0.0,
        position.maxScrollExtent,
      ),
      duration: Motion.base,
      curve: Curves.easeOutCubic,
    );
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
    // The chevrons are the first thing to go when the rail itself runs out of
    // room, and this is not a preference — it is the only arrangement that
    // fits. Their own doc says they earn their place "while the overflow is
    // mild"; below [_chevronsFitFrom] the overflow is not mild, it is the rail
    // being squeezed to less than one tab by whatever shares the strip with it,
    // and a row of `chevron + Expanded + chevron + picker` needs ~100px of
    // chrome to draw. Built anyway it overflowed by 8.8px in a 640-wide window
    // — a striped bar across the tab strip, from adding one control at the
    // other end of the row.
    //
    // The picker stays at every width: it is "the only affordance here that
    // still works at a hundred", and the chevrons only page a list it can
    // filter.
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

  /// [list], with the strip's oldest unwritten gesture laid over whatever room
  /// the tabs did not use: **double-click the empty space to open a tab**, as
  /// VS Code, every browser and most terminals do.
  ///
  /// A sibling over the leftover pixels, and deliberately **not** a detector
  /// wrapped around the rail. An ancestor `onDoubleTap` joins the gesture arena
  /// for every pointer that lands on a chip, and it breaks the chip twice over:
  /// a double-click on a tab would open a new one instead of activating it,
  /// and — worse, because it is silent — every *single* click on a tab would
  /// wait out the 300 ms double-tap window before the chip's own `onTap` could
  /// win the arena. Here it covers only pixels no chip occupies, which is
  /// exactly the target the gesture is about.
  ///
  /// `Stack` hit-tests its children topmost-first and stops at the first that
  /// answers, so the list keeps every pointer over a chip and this keeps the
  /// rest. The `DragTarget` around the whole strip is an *ancestor* and stays
  /// on the hit-test path either way, so dropping a pane on the empty space
  /// still turns it into a tab.
  ///
  /// Only reached when the tabs fit. An overflowing rail has no empty space by
  /// definition, and the arm above returns the row of chevrons instead.
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
          // Two gestures over the same pixels, and they do not compete: the
          // double-click is a pointer gesture and the drop is resolved by the
          // drag avatar's own hit test. The target is the *outer* of the two so
          // the detector underneath still answers the hit that puts both of
          // them on the path — and a pane is refused here so it carries on up
          // to the strip's target and becomes a tab, as it always has.
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
                  // Against the last chip rather than out in the middle of the
                  // empty room: the mark says where the tab lands, and it lands
                  // immediately after the tabs, not where the pointer is.
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
      // pixels and extents do not exist until the viewport has been laid out —
      // and reading `maxScrollExtent` before then throws. Both chevrons are
      // simply off for that one frame.
      //
      // Half a pixel of slack at the ends: a scroll that has arrived can sit a
      // rounding error short, and a chevron that stays enabled at the end is a
      // button that does nothing.
      final can =
          position != null &&
          position.hasPixels &&
          position.hasContentDimensions &&
          (forward
              ? position.pixels < position.maxScrollExtent - 0.5
              : position.pixels > 0.5);
      // Shaped like the terminal toolbar's buttons at the other end of the
      // strip rather than like a tab's own close button: these are chrome that
      // acts on the strip, and they are the two the mouse aims at most.
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
            border: Border(left: BorderSide(color: scheme.outlineVariant)),
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
