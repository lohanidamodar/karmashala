// **The floating handle on a pane of a split** — the grip that starts the
// [PaneDrag]. A `part` because `_PaneFloatingActions` is private.

part of 'terminal_panel.dart';

/// The grip a split pane is dragged out by. Named rather than found by
/// geometry: the handle *is* the subject of the gesture.
Key paneDragHandleKey(String paneId) => ValueKey('pane-handle/$paneId');

/// The floating handle in a split pane's top-right corner. A region draws no
/// header, so this grip is the pane's only way to be dragged anywhere.
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
        duration: Motion.of(context).fast,
        // Invisible is also unclickable and no Tab stop; the box stays so the
        // hover target and the geometry are the same in every state.
        child: ExcludeFocus(
          excluding: opacity == 0.0,
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
                          width: Chrome.icon,
                          height: DenseIconButton.inRow,
                          child: Icon(
                            AppIcons.dotsSixVertical,
                            size: Chrome.iconAction,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ),
                  DenseIconButton(
                    tooltip: 'Move pane to a new tab',
                    color: scheme.onSurfaceVariant,
                    icon: const Icon(AppIcons.terminalWindow),
                    onPressed: widget.onMoveToNewTab,
                  ),
                  const SizedBox(width: 2),
                  DenseIconButton(
                    tooltip: 'Close pane',
                    color: scheme.onSurfaceVariant,
                    icon: const Icon(AppIcons.x),
                    onPressed: widget.onClose,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
