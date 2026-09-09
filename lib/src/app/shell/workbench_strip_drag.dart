part of 'workbench.dart';

// What the strip does while something is being dragged over it: the marks it
// draws, and the target on each chip that reads them.

/// The insertion mark the strip draws while a tab is being dragged over it.
///
/// A drop that only announces itself by its result is a drop nobody aims: the
/// strip has to say *where this will land* while the button is still down, the
/// way every browser and editor does. Exactly one is ever on screen — a drag
/// has one active target at a time — so a test can find *the* mark and read its
/// rect to say which edge of which chip it is on.
const kTabDropMarker = Key('tab-strip/drop-marker');

/// The chip a pane will join, or a tab will divide the workspace beside.
///
/// A whole-chip mark rather than the edge caret [_markedForDrop] draws: neither
/// drop lands the thing *between* two chips, so an edge would be pointing at a
/// position that does not exist.
const kPaneJoinMarker = Key('tab-strip/pane-join-marker');
const kTabSplitMarker = Key('tab-strip/split-marker');

/// [child] under a tinted, outlined box carrying [icon].
Widget _markedForJoin(
  BuildContext context,
  Widget child, {
  required Key key,
  IconData icon = AppIcons.plus,
}) {
  final scheme = Theme.of(context).colorScheme;
  return Stack(
    fit: StackFit.passthrough,
    children: [
      child,
      Positioned.fill(
        key: key,
        // A statement, not a target — the same reason [_markedForDrop] gives.
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.15),
              border: Border.all(color: scheme.primary, width: 2),
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: Center(
              child: Icon(icon, size: Chrome.iconSmall, color: scheme.primary),
            ),
          ),
        ),
      ),
    ],
  );
}

/// [child] with [kTabDropMarker] laid down its leading or trailing edge.
Widget _markedForDrop(
  BuildContext context,
  Widget child, {
  required bool leading,
}) => Stack(
  fit: StackFit.passthrough,
  children: [
    child,
    Positioned(
      key: kTabDropMarker,
      left: leading ? 0 : null,
      right: leading ? null : 0,
      top: 0,
      bottom: 0,
      width: 2,
      // The mark is a statement, not a target: a drag is hit-tested through
      // the avatar, and 2px of the chip that answered a pointer differently
      // while a drag was over it would be a control nobody meant to make.
      child: IgnorePointer(
        child: ColoredBox(color: Theme.of(context).colorScheme.primary),
      ),
    ),
  ],
);

/// The drop target on a tab chip: reorders tabs when dragged over, and splits
/// the tab when dropped with Ctrl held.
class _TabDropTarget extends ConsumerStatefulWidget {
  const _TabDropTarget({
    required this.index,
    required this.tab,
    required this.groupId,
    required this.chip,
  });

  final int index;
  final TerminalTab tab;

  /// The strip this chip is in. A tab from **another** group lands here as a
  /// move rather than a reorder — the drop that makes groups worth having.
  final String? groupId;

  final Widget chip;

  @override
  ConsumerState<_TabDropTarget> createState() => _TabDropTargetState();
}

class _TabDropTargetState extends ConsumerState<_TabDropTarget> {
  /// How near the middle of a chip counts as *on* it, in logical pixels.
  static const _centreSlack = 1.0;

  bool _dropLeading = true;
  bool _ctrlPressed = false;

  void _updatePosition(TerminalDrag data, Offset globalPos) {
    final box = context.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize && box.size.width > 0) {
      final offMiddle = box.globalToLocal(globalPos).dx - box.size.width / 2;
      // Which half the pointer is over says where the tab lands. Dead centre
      // is not a coin flip: it goes the way the drag came from, which is the
      // whole rule the strip had before it had halves.
      final leading = offMiddle.abs() <= _centreSlack
          ? _comesFromTheRight(data)
          : offMiddle < 0;
      final ctrl = HardwareKeyboard.instance.isControlPressed ||
          HardwareKeyboard.instance.isMetaPressed;
      if (leading != _dropLeading || ctrl != _ctrlPressed) {
        setState(() {
          _dropLeading = leading;
          _ctrlPressed = ctrl;
        });
      }
    }
  }

  bool _comesFromTheRight(TerminalDrag data) =>
      data is TabDrag && _indexInStrip(data.tabId) > widget.index;

  /// The region of this tab a dropped **pane** joins.
  ///
  /// The chip is the only place a *background* tab can be addressed at all: the
  /// workbench shows one tab's regions at a time, so a pane can be dropped onto
  /// a region only while its tab is in front. Dropping on the chip says "into
  /// that tab" and the front region of the tab's focused group is where it
  /// lands — the same place a new pane would.
  String get _paneAnchor =>
      widget.tab.layout.groupOf(widget.tab.focusedPaneId)?.activePaneId ??
      widget.tab.focusedPaneId;

  /// Where [tabId] sits in *this* strip, or -1 when it is in another group's.
  int _indexInStrip(String tabId) {
    final group = widget.groupId;
    final tabs = group == null
        ? ref.read(terminalTabsProvider)
        : ref.read(terminalSessionsControllerProvider.notifier).tabsInGroup(
            group,
          );
    return tabs.indexWhere((tab) => tab.id == tabId);
  }

  @override
  Widget build(BuildContext context) {
    final sessions = ref.read(terminalSessionsControllerProvider.notifier);
    return DragTarget<TerminalDrag>(
      onWillAcceptWithDetails: (details) => switch (details.data) {
        TabDrag(:final tabId) => () {
          _updatePosition(details.data, details.offset);
          return tabId != widget.tab.id;
        }(),
        // Which half of the chip the pointer is over means nothing to a pane —
        // a tab is a destination here, not a place in a list — so the position
        // is left alone and the whole chip lights up instead.
        PaneDrag(:final paneId) => sessions.canMovePaneIntoRegion(
          paneId,
          _paneAnchor,
        ),
      },
      onMove: (details) => _updatePosition(details.data, details.offset),
      onLeave: (_) {
        if (mounted) {
          setState(() {
            _ctrlPressed = false;
          });
        }
      },
      onAcceptWithDetails: (details) {
        // The pane keeps its id, its process and its buffer: the controller
        // moves it between the two tabs' layouts and never touches
        // `_instances`, so the terminal is the same object at a new address.
        if (details.data case PaneDrag(:final paneId)) {
          sessions.movePaneIntoRegion(paneId, _paneAnchor);
          return;
        }
        if (details.data case TabDrag(:final tabId)) {
          final ctrl = HardwareKeyboard.instance.isControlPressed ||
              HardwareKeyboard.instance.isMetaPressed ||
              _ctrlPressed;
          // Ctrl-drop divides the **workspace** and puts the tab in the new
          // group, not the tab it was dropped on: a tab carries a session, a
          // view and a status strip together, and only a group can host that.
          if (ctrl && tabId != widget.tab.id && widget.groupId != null) {
            sessions.moveTabBesideGroup(
              tabId,
              widget.groupId!,
              SplitAxis.horizontal,
              insertBefore: _dropLeading,
            );
          } else {
            final from = _indexInStrip(tabId);
            if (from >= 0) {
              final insertIndex = _dropLeading
                  ? (from < widget.index ? widget.index - 1 : widget.index)
                  : (from < widget.index ? widget.index : widget.index + 1);
              sessions.reorderTab(tabId, insertIndex);
            } else if (widget.groupId case final group?) {
              // From another group's strip: it moves here, at the edge of this
              // chip the pointer is over.
              sessions.moveTabToGroup(
                tabId,
                group,
                index: _dropLeading ? widget.index : widget.index + 1,
              );
            }
          }
        }
      },
      builder: (context, candidate, _) {
        final incoming = candidate.isEmpty ? null : candidate.first;
        // A pane joins the whole tab, so the whole chip is marked. The caret a
        // tab drop draws would be a lie: there is no position to land at.
        if (incoming is PaneDrag) {
          return _markedForJoin(context, widget.chip, key: kPaneJoinMarker);
        }
        if (incoming is! TabDrag) return widget.chip;

        if (_ctrlPressed) {
          return _markedForJoin(
            context,
            widget.chip,
            key: kTabSplitMarker,
            icon: AppIcons.squareSplitHorizontal,
          );
        }

        return _markedForDrop(
          context,
          widget.chip,
          leading: _dropLeading,
        );
      },
    );
  }
}

/// What a dragged tab looks like under the pointer.
///
/// Deliberately not the chip itself: the chip is as wide as the strip gave it
/// and carries a close button, and dragging a control that can still be clicked
/// reads as a bug. A label is enough to say which tab is in flight.
class _TabDragFeedback extends StatelessWidget {
  const _TabDragFeedback({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      elevation: 4,
      borderRadius: BorderRadius.circular(Radii.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.sm,
          vertical: Insets.xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              AppIcons.terminal,
              size: Chrome.icon,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: Insets.xs),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 200),
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
