// **The floating handle on a pane of a split** — the grip a pane is dragged
// out by, and the two verbs that used to live in a per-region header. A region
// of a split draws no header any more, so this is the pane's only handle: it
// starts the [PaneDrag] that lets a pane be dropped on the tab strip to become
// a tab, on another region's header to join it, or on another pane to
// re-split.
//
// A part of `terminal_panel.dart` rather than a library of its own, because
// `_PaneFloatingActions` is private and the panel's tree golden records that
// name. `paneDragHandleKey` travels with it: the key is the handle's, and a
// test aiming at the grip is aiming at this widget.

part of 'terminal_panel.dart';

/// The grip a split pane is dragged out by, so a test can aim at it.
///
/// Named rather than found by geometry for the reason [kTabStripEmptySpace] is:
/// the handle *is* the subject of the gesture.
Key paneDragHandleKey(String paneId) => ValueKey('pane-handle/$paneId');

/// The floating handle in the top-right corner of a split pane: a grip to drag
/// the pane by, and the two verbs that used to live in a per-region header.
///
/// A region of a split no longer draws a header (see [_buildRegion]), so this
/// is the pane's only handle — including the grip that starts a [PaneDrag],
/// which is what still lets a pane be dropped on the tab strip to become a tab,
/// on another region's header to join it, or on another pane to re-split.
class _PaneFloatingActions extends ConsumerStatefulWidget {
  const _PaneFloatingActions({
    required this.paneId,
    required this.focused,
    required this.onMoveToNewTab,
    required this.onClose,
  });

  final String paneId;
  final bool focused;
  final VoidCallback onMoveToNewTab;
  final VoidCallback onClose;

  @override
  ConsumerState<_PaneFloatingActions> createState() =>
      _PaneFloatingActionsState();
}

class _PaneFloatingActionsState extends ConsumerState<_PaneFloatingActions> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final opacity = _hovered ? 1.0 : (widget.focused ? 0.35 : 0.0);
    final title = ref.watch(terminalPaneTitleProvider(widget.paneId));

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedOpacity(
        opacity: opacity,
        duration: const Duration(milliseconds: 150),
        // Invisible is also unclickable: the box stays to keep the hover
        // target and the geometry the same in every state.
        child: IgnorePointer(
          ignoring: opacity == 0.0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.5),
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Draggable<TerminalDrag>(
                  key: paneDragHandleKey(widget.paneId),
                  data: PaneDrag(widget.paneId),
                  dragAnchorStrategy: pointerDragAnchorStrategy,
                  feedback: PaneDragFeedback(title: title),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.grab,
                    child: Tooltip(
                      message: 'Drag the pane elsewhere',
                      child: SizedBox(
                        width: 16,
                        height: 22,
                        child: Icon(
                          AppIcons.dotsSixVertical,
                          size: 14,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Move pane to a new tab',
                  iconSize: Chrome.iconSmall,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
                  padding: EdgeInsets.zero,
                  icon: Icon(
                    AppIcons.terminalWindow,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                  onPressed: widget.onMoveToNewTab,
                ),
                const SizedBox(width: 2),
                IconButton(
                  tooltip: 'Close pane',
                  iconSize: Chrome.iconSmall,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
                  padding: EdgeInsets.zero,
                  icon: Icon(
                    AppIcons.x,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                  onPressed: widget.onClose,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
