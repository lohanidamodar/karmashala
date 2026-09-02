import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/quick_open/quick_open_item.dart';
import '../../../app/shell/tab_picker.dart';
import '../../../app/shell/tab_strip_metrics.dart';
import '../../../app/shell/workbench_tab_chip.dart';
import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_menu.dart';
import '../application/terminal_sessions_controller.dart';
import '../domain/pane_layout.dart';
import '../domain/terminal_drag.dart';
import 'session_status.dart';

/// The header one region of a split draws for the panes stacked in it.
///
/// The report this exists for: *"tab moved to a split pane, doesn't have the
/// tab header to move it away from etc, each split pane should show it's own
/// tab header right?"*. A pane dragged into a split had no header, so it had no
/// handle — nothing said what it was, and there was no way to close it or take
/// it back out. This is that handle, and it is what lets a region hold more
/// than one pane at all.
///
/// **It costs one [Chrome.tabStrip] row and no more.** That token already names
/// "the workbench tab strip, the side panel's header and every pane header", so
/// a region header is the same 30px row as everything else in the chrome rather
/// than a new density invented for it. Vertical space in a terminal is the
/// scarcest thing there is, which is also why the header is not drawn at all
/// while a tab has one region holding one pane: the workbench strip is already
/// that pane's header, and a second copy of it would be 30px saying nothing.
class PaneGroupStrip extends ConsumerWidget {
  const PaneGroupStrip({
    required this.group,
    required this.focused,
    super.key,
  });

  final PaneGroup group;

  /// Whether the keyboard is in this region. Only the focused region's selected
  /// tab draws the accent, so a split says where typing will go.
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
        height: Chrome.tabStrip,
        color: candidate.isEmpty
            ? scheme.surfaceContainerLow
            // The same wash the empty region uses, so "this will land here"
            // looks the same wherever a drag is over.
            : scheme.primary.withValues(alpha: 0.08),
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
            // A region can be dragged down to `kMinPaneWeight` of the tab, so
            // even at the floor extent the chips may not fit. Scrolling is the
            // only honest answer there; the workbench strip's picker is not,
            // because these are the tabs of *this* region.
            return metrics.overflowing
                ? SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: chips),
                  )
                : Row(children: chips);
          },
        ),
      ),
    );
  }
}

/// Whether [drag] can land in the region holding [anchorPaneId].
bool _accepts(
  TerminalSessionsController sessions,
  TerminalDrag drag,
  String anchorPaneId,
) => switch (drag) {
  TabDrag(:final tabId) => sessions.canMoveTabIntoSlot(tabId, anchorPaneId),
  PaneDrag(:final paneId) =>
    sessions.canMovePaneIntoRegion(paneId, anchorPaneId),
};

void _drop(
  TerminalSessionsController sessions,
  TerminalDrag drag,
  String anchorPaneId,
) => switch (drag) {
  TabDrag(:final tabId) => sessions.moveTabIntoSlot(tabId, anchorPaneId),
  PaneDrag(:final paneId) =>
    sessions.movePaneIntoRegion(paneId, anchorPaneId),
};

/// One pane's tab in a region header.
///
/// Drags as a [PaneDrag], which is what makes the move a two-way street: the
/// same chip can be dropped on another region's header, on an empty region, or
/// back on the workbench strip to become a tab of its own again.
class PaneTabChip extends ConsumerWidget {
  const PaneTabChip({
    required this.paneId,
    required this.selected,
    required this.accented,
    super.key,
  });

  /// The key a test — or anything else that has to find one chip among several
  /// — addresses this chip by. Stated here so nobody has to spell the string.
  static Key keyFor(String paneId) => ValueKey('pane-tab/$paneId');

  final String paneId;

  /// Whether this is the pane its region is showing.
  final bool selected;

  /// Whether it is also the pane the keyboard is in.
  final bool accented;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.read(terminalSessionsControllerProvider.notifier);
    // Per pane, not per layout: a process dying redraws its own chip and
    // leaves the rest of the header alone — the rule the workbench strip
    // already follows.
    final liveness = ref.watch(terminalPaneLivenessProvider(paneId));
    final title = sessions.titleForPane(paneId);

    final chip = WorkbenchTabChip(
      selected: selected,
      accented: accented,
      onTap: () => sessions.focusPane(paneId),
      onSecondaryTapDown: (details) =>
          _menu(context, sessions, details.globalPosition),
      leading: TabLivenessDot(liveness: liveness),
      label: title,
      tooltip: title,
      trailing: IconButton(
        tooltip: liveness.isLive
            ? 'Close pane (the session keeps running)'
            : 'Close pane',
        iconSize: 13,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
        padding: EdgeInsets.zero,
        icon: const Icon(AppIcons.x),
        onPressed: () => sessions.closePane(paneId),
      ),
    );

    return Draggable<TerminalDrag>(
      data: PaneDrag(paneId),
      feedback: _PaneDragFeedback(title: title),
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
      // `ContextMenuRegion._show`'s anchor. As in the workbench strip, the chip
      // keeps `showMenu`: the right-click already comes from
      // [WorkbenchTabChip]'s `InkWell`, and this chip is inside a `Draggable`.
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

/// What a dragged pane looks like under the pointer — the same label-only
/// treatment a dragged tab gets, and for the same reason: dragging a
/// control that can still be clicked reads as a bug.
class _PaneDragFeedback extends StatelessWidget {
  const _PaneDragFeedback({required this.title});

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

/// Where the pane [paneId] could go, as [TabPicker] lists it: every other
/// region of its tab, and a tab of its own.
///
/// The keyboard's way to do what dragging a chip out of a header does. "A new
/// tab" belongs in the *same* list rather than in a second command because it
/// is an answer to the same question — where should this pane live — and
/// splitting it out would make the way back out of a split the one destination
/// you had to already know the name of.
List<TabEntry> regionsMovableTo(WidgetRef ref, String paneId) {
  // Watched, not read: the list has to be rebuilt when a move changes what is
  // left to move to, the same way the tab picker's own list is.
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
