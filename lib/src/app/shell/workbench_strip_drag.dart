part of 'workbench.dart';

/// The insertion mark the strip draws while a tab is being dragged over it.
/// Exactly one is ever on screen, so a test can read *the* mark's rect.
const kTabDropMarker = Key('tab-strip/drop-marker');

/// The chip a pane will join, or a tab will divide the workspace beside — a
/// whole-chip mark, because neither drop lands the thing *between* two chips.
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
              color: StateLayers.dropTarget(scheme),
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
      // The mark is a statement, not a target: a drag is hit-tested through the
      // avatar, and a chip answering a pointer differently would be a control.
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
      // Which half the pointer is over says where the tab lands. Dead centre is
      // not a coin flip: it goes the way the drag came from.
      final leading = offMiddle.abs() <= _centreSlack
          ? _comesFromTheRight(data)
          : offMiddle < 0;
      final ctrl =
          HardwareKeyboard.instance.isControlPressed ||
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

  /// The region of this tab a dropped **pane** joins: the chip is the only way
  /// to address a *background* tab, so a drop on it lands in the front region.
  String get _paneAnchor =>
      widget.tab.layout.groupOf(widget.tab.focusedPaneId)?.activePaneId ??
      widget.tab.focusedPaneId;

  /// Where [tabId] sits in *this* strip, or -1 when it is in another group's.
  int _indexInStrip(String tabId) {
    final group = widget.groupId;
    final tabs = group == null
        ? ref.read(terminalTabsProvider)
        : ref
              .read(terminalSessionsControllerProvider.notifier)
              .tabsInGroup(group);
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
        // a tab is a destination here, not a place in a list.
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
        // The pane keeps its id, its process and its buffer: only the two tabs'
        // layouts change, and `_instances` is never touched.
        if (details.data case PaneDrag(:final paneId)) {
          sessions.movePaneIntoRegion(paneId, _paneAnchor);
          return;
        }
        if (details.data case TabDrag(:final tabId)) {
          final ctrl =
              HardwareKeyboard.instance.isControlPressed ||
              HardwareKeyboard.instance.isMetaPressed ||
              _ctrlPressed;
          // Ctrl-drop divides the **workspace** and puts the tab in the new
          // group: a tab carries a session and a strip, which only a group hosts.
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

        return _markedForDrop(context, widget.chip, leading: _dropLeading);
      },
    );
  }
}

/// What a dragged tab looks like under the pointer. Not the chip itself: it
/// carries a close button, and dragging a clickable control reads as a bug.
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
