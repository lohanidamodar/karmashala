// **The drop target over a pane** — the four edge zones and the "Drop to split"
// overlay, alive only while something is being dragged. A **tab** dropped here
// divides the workspace group; a **pane** divides the tab.
//
// A `part` because both types are private.

part of 'terminal_panel.dart';

enum _SplitDropZone { left, right, top, bottom }

/// A drop target over an active terminal pane that allows splitting the pane
/// horizontally or vertically by dragging another tab or pane over it.
class _PaneDropTarget extends ConsumerStatefulWidget {
  const _PaneDropTarget({
    required this.paneId,
    required this.groupId,
    required this.child,
  });

  final String paneId;

  /// The workspace group this pane is in — what a **tab** dropped on an edge
  /// divides. See [TerminalSessionsController.moveTabBesideGroup].
  final String? groupId;

  final Widget child;

  @override
  ConsumerState<_PaneDropTarget> createState() => _PaneDropTargetState();
}

class _PaneDropTargetState extends ConsumerState<_PaneDropTarget> {
  _SplitDropZone? _activeZone;

  void _updateZone(Offset globalPos) {
    final box = context.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize && box.size.width > 0 && box.size.height > 0) {
      final local = box.globalToLocal(globalPos);
      final dx = (local.dx / box.size.width).clamp(0.0, 1.0);
      final dy = (local.dy / box.size.height).clamp(0.0, 1.0);
      final distH = (dx - 0.5).abs();
      final distV = (dy - 0.5).abs();
      final zone = distH >= distV
          ? (dx < 0.5 ? _SplitDropZone.left : _SplitDropZone.right)
          : (dy < 0.5 ? _SplitDropZone.top : _SplitDropZone.bottom);
      if (zone != _activeZone) {
        setState(() => _activeZone = zone);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessions = ref.read(terminalSessionsControllerProvider.notifier);
    return DragTarget<TerminalDrag>(
      onWillAcceptWithDetails: (details) {
        final data = details.data;
        final group = widget.groupId;
        final accepts = switch (data) {
          TabDrag(:final tabId) =>
            group != null && sessions.canMoveTabBesideGroup(tabId, group),
          PaneDrag(:final paneId) =>
            sessions.canSplitPaneWithPane(widget.paneId, paneId),
        };
        if (accepts) {
          _updateZone(details.offset);
        }
        return accepts;
      },
      onMove: (details) => _updateZone(details.offset),
      onLeave: (_) {
        if (mounted && _activeZone != null) {
          setState(() => _activeZone = null);
        }
      },
      onAcceptWithDetails: (details) {
        final zone = _activeZone ?? _SplitDropZone.right;
        final axis = (zone == _SplitDropZone.left || zone == _SplitDropZone.right)
            ? SplitAxis.horizontal
            : SplitAxis.vertical;
        final insertBefore =
            (zone == _SplitDropZone.left || zone == _SplitDropZone.top);

        switch (details.data) {
          case TabDrag(:final tabId):
            if (widget.groupId case final group?) {
              sessions.moveTabBesideGroup(
                tabId,
                group,
                axis,
                insertBefore: insertBefore,
              );
            }
          case PaneDrag(:final paneId):
            sessions.splitPaneWithPane(
              widget.paneId,
              paneId,
              axis,
              insertBefore: insertBefore,
            );
        }
        if (mounted) setState(() => _activeZone = null);
      },
      builder: (context, candidate, _) {
        if (candidate.isEmpty || _activeZone == null) {
          return widget.child;
        }

        final theme = Theme.of(context);
        final isHorizontal =
            _activeZone == _SplitDropZone.left || _activeZone == _SplitDropZone.right;

        return Stack(
          children: [
            widget.child,
            Positioned.fill(
              child: Align(
                alignment: switch (_activeZone!) {
                  _SplitDropZone.left => Alignment.centerLeft,
                  _SplitDropZone.right => Alignment.centerRight,
                  _SplitDropZone.top => Alignment.topCenter,
                  _SplitDropZone.bottom => Alignment.bottomCenter,
                },
                child: FractionallySizedBox(
                  widthFactor: isHorizontal ? 0.5 : 1.0,
                  heightFactor: isHorizontal ? 1.0 : 0.5,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: 0.18),
                        border: Border.all(
                          color: theme.colorScheme.primary,
                          width: 2,
                        ),
                      ),
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: Insets.sm,
                            vertical: Insets.xs,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary,
                            borderRadius: BorderRadius.circular(Radii.sm),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                isHorizontal
                                    ? AppIcons.squareSplitHorizontal
                                    : AppIcons.squareSplitVertical,
                                size: Chrome.iconSmall,
                                color: theme.colorScheme.onPrimary,
                              ),
                              const SizedBox(width: Insets.xs),
                              Text(
                                'Drop to split',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onPrimary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
