import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/quick_open/quick_open_item.dart';
import '../../../app/shell/tab_picker.dart';
import '../../../app/shell/tab_strip_metrics.dart';
import '../../../app/shell/workbench_tab_chip.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/menus.dart';
import '../../sessions/application/session_status_providers.dart';
import '../application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'session_status.dart';

/// The header one region of a split draws for the panes stacked in it.
/// **Deliberately not the tab strip**: it differs by shape and never by colour.
class PaneGroupStrip extends ConsumerWidget {
  const PaneGroupStrip({
    required this.group,
    required this.focused,
    super.key,
  });

  final PaneGroup group;

  /// Only the focused region's selected tab draws the accent, so a split says
  /// where typing will go.
  final bool focused;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final sessions = ref.read(terminalSessionsControllerProvider.notifier);

    return DragTarget<TerminalDrag>(
      onWillAcceptWithDetails: (details) =>
          _accepts(sessions, details.data, group.activePaneId),
      onAcceptWithDetails: (details) =>
          _drop(sessions, details.data, group.activePaneId),
      builder: (context, candidate, _) => Container(
        height: Chrome.paneStrip,
        color: candidate.isEmpty
            ? scheme.surfaceContainerLow
            // The same wash the empty region uses, so "this will land here"
            // reads the same wherever a drag is over.
            : scheme.primary.withValues(alpha: 0.08),
        child: Row(
          children: [
            // What the row is, before the first name on it. Not a control:
            // every verb here is already on the chips and the region menu.
            Tooltip(
              message: 'The panes in this region of the split',
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
                child: Icon(
                  AppIcons.squareSplitHorizontal,
                  size: Chrome.iconSmall,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final metrics = tabStripMetrics(
                    constraints.maxWidth,
                    group.panes.length,
                    min: kMinRegionTabWidth,
                    max: kMaxRegionTabWidth,
                  );
                  final chips = [
                    for (final paneId in group.panes)
                      SizedBox(
                        width: metrics.extent,
                        child: PaneTabChip(
                          key: PaneTabChip.keyFor(paneId),
                          paneId: paneId,
                          selected: paneId == group.activePaneId,
                          accented: focused && paneId == group.activePaneId,
                        ),
                      ),
                  ];
                  // A region shrinks to `kMinPaneWeight` of the tab, so the
                  // chips may not fit: they scroll, and a menu names them all.
                  return metrics.overflowing
                      ? _CrowdedChips(group: group, chips: chips)
                      : Row(children: chips);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// More chips than the header holds: a row that scrolls — a plain mouse wheel
/// included, since it is the only wheel most mice have — and a menu of every
/// pane in the region, so the ones scrolled out of sight are one click away.
class _CrowdedChips extends ConsumerStatefulWidget {
  const _CrowdedChips({required this.group, required this.chips});

  final PaneGroup group;
  final List<Widget> chips;

  @override
  ConsumerState<_CrowdedChips> createState() => _CrowdedChipsState();
}

class _CrowdedChipsState extends ConsumerState<_CrowdedChips> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_scroll.hasClients) return;
    final delta = event.scrollDelta.dx != 0
        ? event.scrollDelta.dx
        : event.scrollDelta.dy;
    final position = _scroll.position;
    final target = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (target == position.pixels) return;
    GestureBinding.instance.pointerSignalResolver.register(
      event,
      (_) => _scroll.jumpTo(target),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sessions = ref.read(terminalSessionsControllerProvider.notifier);
    final group = widget.group;
    return Row(
      children: [
        Expanded(
          child: Listener(
            onPointerSignal: _onPointerSignal,
            child: SingleChildScrollView(
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              child: Row(children: widget.chips),
            ),
          ),
        ),
        PopupMenuButton<String>(
          tooltip: 'Every pane in this region',
          padding: EdgeInsets.zero,
          iconSize: Chrome.iconSmall,
          style: IconButton.styleFrom(
            minimumSize: Size.zero,
            fixedSize: const Size.square(Chrome.paneStrip),
          ),
          icon: const Icon(AppIcons.caretDown),
          itemBuilder: (context) => [
            for (final paneId in group.panes)
              DesktopMenuItem(
                value: paneId,
                label: sessions.titleForPane(paneId),
                icon: AppIcons.terminal,
                selected: paneId == group.activePaneId,
              ),
          ],
          onSelected: sessions.focusPane,
        ),
      ],
    );
  }
}

/// Whether [drag] can land in the region holding [anchorPaneId].
bool _accepts(
  TerminalSessionsController sessions,
  TerminalDrag drag,
  String anchorPaneId,
) => switch (drag) {
  // Panes only: a **tab** belongs in a workspace group's strip, where it keeps
  // the status bar it owns.
  TabDrag() => false,
  PaneDrag(:final paneId) =>
    sessions.canMovePaneIntoRegion(paneId, anchorPaneId),
};

void _drop(
  TerminalSessionsController sessions,
  TerminalDrag drag,
  String anchorPaneId,
) => switch (drag) {
  TabDrag() => false,
  PaneDrag(:final paneId) =>
    sessions.movePaneIntoRegion(paneId, anchorPaneId),
};

/// One pane's tab in a region header. Drags as a [PaneDrag], so the same chip
/// can be dropped on another region, on an empty one, or back on the workbench
/// strip to become a tab of its own again.
class PaneTabChip extends ConsumerWidget {
  const PaneTabChip({
    required this.paneId,
    required this.selected,
    required this.accented,
    super.key,
  });

  /// The key anything looking for one chip among several addresses it by.
  static Key keyFor(String paneId) => ValueKey('pane-tab/$paneId');

  final String paneId;

  /// Whether this is the pane its region is showing.
  final bool selected;

  /// Whether it is also the pane the keyboard is in.
  final bool accented;

  /// The seam a cost test counts through: a status change must redraw the one
  /// chip it is about, not the header.
  @visibleForTesting
  static int debugBuildCount = 0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    debugBuildCount++;
    final sessions = ref.read(terminalSessionsControllerProvider.notifier);
    // Per pane, not per layout: a process dying redraws its own chip and leaves
    // the rest of the header alone.
    final liveness = ref.watch(terminalPaneLivenessProvider(paneId));
    // Narrowed to the status word, so a registry cycle that reconfirms it
    // redraws nothing. Null when the liveness marker takes the slot back.
    final activity = ref.watch(paneAgentActivityProvider(paneId));
    final title = ref.watch(terminalPaneTitleProvider(paneId));

    final chip = WorkbenchTabChip(
      selected: selected,
      accented: accented,
      // Shorter, quieter and ruled underneath — see [PaneGroupStrip] for why
      // the two rows must not look alike.
      dense: true,
      onTap: () => sessions.focusPane(paneId),
      onSecondaryTapDown: (details) =>
          _menu(context, sessions, details.globalPosition),
      // Middle click, the same close this pane's X performs. Wired here too
      // because a gesture that worked in the workbench strip and not in a
      // group's would be worse than not having it at all.
      onClose: () => sessions.closePane(paneId),
      leading: activity == null
          ? TabLivenessDot(liveness: liveness)
          : TabAgentStatusDot(status: activity),
      label: title,
      tooltip: title,
      trailing: IconButton(
        tooltip: liveness.isLive
            ? 'Close pane (the session keeps running)'
            : 'Close pane',
        iconSize: Chrome.iconSmall,
        visualDensity: VisualDensity.compact,
        // A [Chrome.paneStrip] row with a 2px rule under it leaves 22px; the
        // workbench strip's 20px box fits with no gutter at all.
        constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
        padding: EdgeInsets.zero,
        icon: const Icon(AppIcons.x),
        onPressed: () => sessions.closePane(paneId),
      ),
    );

    return Draggable<TerminalDrag>(
      data: PaneDrag(paneId),
      // The split zone a pane lands in is read off this offset, so it has to be
      // the pointer.
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: PaneDragFeedback(title: title),
      childWhenDragging: Opacity(opacity: 0.4, child: chip),
      child: chip,
    );
  }

  Future<void> _menu(
    BuildContext context,
    TerminalSessionsController sessions,
    Offset position,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final choice = await showMenu<String>(
      context: context,
      // `ContextMenuRegion._show`'s anchor. The chip keeps `showMenu`: the
      // right-click comes from [WorkbenchTabChip]'s `InkWell`, inside a
      // `Draggable`.
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        DesktopMenuItem(
          value: 'untangle',
          label: 'Move to a new tab',
          icon: AppIcons.terminalWindow,
        ),
        DesktopMenuItem(
          value: 'close',
          label: 'Close pane, keep running',
          icon: AppIcons.x,
        ),
        const DesktopMenuDivider(),
        DesktopMenuItem(
          value: 'end',
          label: 'End session',
          icon: AppIcons.power,
          destructive: true,
        ),
      ],
    );
    switch (choice) {
      case 'untangle':
        sessions.movePaneToNewTab(paneId);
      case 'close':
        sessions.closePane(paneId);
      case 'end':
        sessions.endSession(paneId);
    }
  }
}

/// What a dragged pane looks like under the pointer: label only, because
/// dragging a control that can still be clicked reads as a bug. Shared with the
/// grip a split pane is dragged out by.
class PaneDragFeedback extends StatelessWidget {
  const PaneDragFeedback({required this.title, super.key});

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

/// Where the pane [paneId] could go: every other region of its tab, and a tab
/// of its own — the keyboard's way to do what dragging a chip out does.
List<TabEntry> regionsMovableTo(WidgetRef ref, String paneId) {
  // Watched, not read: a move changes what is left to move to.
  ref.watch(terminalSessionsControllerProvider);
  final sessions = ref.read(terminalSessionsControllerProvider.notifier);
  final anchors = sessions.regionAnchorsBesides(paneId);
  return [
    for (final anchor in anchors)
      TabEntry(
        item: QuickOpenItem(
          id: 'move-pane-to/$anchor',
          group: QuickOpenGroup.tabs,
          title: sessions.titleForPane(anchor),
          // An empty region has no name of its own, so it says what it is.
          subtitle:
              sessions.instanceFor(anchor)?.workingDirectory ?? 'Empty split',
          icon: AppIcons.squareSplitHorizontal,
          onSelect: () => sessions.movePaneIntoRegion(paneId, anchor),
        ),
        active: false,
      ),
    if (anchors.isNotEmpty)
      TabEntry(
        item: QuickOpenItem(
          id: 'move-pane-to/new-tab',
          group: QuickOpenGroup.tabs,
          title: 'A new tab',
          subtitle: 'Take it out of the split',
          icon: AppIcons.terminalWindow,
          onSelect: () => sessions.movePaneToNewTab(paneId),
        ),
        active: false,
      ),
  ];
}
