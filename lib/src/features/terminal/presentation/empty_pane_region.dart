import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/quick_open/quick_open_item.dart';
import '../../../app/shell/tab_picker.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart';

/// A region of a split with nothing in it yet: what it is, the two ways to fill
/// it, and the way to close it again. **Not a blank rectangle** — that would
/// read as a bug, with nothing to click, tab to or read out.
class EmptyPaneRegion extends ConsumerWidget {
  const EmptyPaneRegion({
    required this.paneId,
    required this.focused,
    this.title = 'Empty split',
    this.closeLabel = 'Close split',
    this.accepts,
    this.onDrop,
    this.onNewTerminal,
    this.onNewSession,
    this.onClose,
    this.onMoveTabHere,
    this.moveLabel = 'Move a pane here…',
    super.key,
  });

  /// The empty region's own pane id, and the drop target's address. An empty
  /// **workspace group** passes its own slot id here with [accepts]/[onDrop]:
  /// the room reads the same either way, only the drop is addressed elsewhere.
  final String paneId;

  /// What the room is called, in its own words.
  final String title;

  /// What the way out is called.
  final String closeLabel;

  /// Whether [drag] can land here, and what happens when it does. Null keeps
  /// the region rules — a group supplies its own.
  final bool Function(TerminalDrag drag)? accepts;
  final void Function(TerminalDrag drag)? onDrop;

  /// Drives the focus ring, and hands the keyboard to the primary action so a
  /// split made from a chord can be filled from one.
  final bool focused;

  final VoidCallback? onNewTerminal;
  final VoidCallback? onNewSession;
  final VoidCallback? onClose;

  /// Opens the list of things that can be moved in here. `null` while there is
  /// nothing to move.
  final VoidCallback? onMoveTabHere;

  /// What that button says: a region takes panes and a group takes tabs, so
  /// the word has to be the right one — see [WorkspaceLayout].
  final String moveLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final sessions = ref.read(terminalSessionsControllerProvider.notifier);
    return DragTarget<TerminalDrag>(
      onWillAcceptWithDetails: (details) =>
          accepts?.call(details.data) ??
          switch (details.data) {
            // A region takes **panes**: a tab carries a session, a view and a
            // status strip together, and only a workspace group hosts that.
            TabDrag() => false,
            PaneDrag(paneId: final moved) => sessions.canMovePaneIntoRegion(
              moved,
              paneId,
            ),
          },
      onAcceptWithDetails: (details) {
        if (onDrop case final drop?) {
          drop(details.data);
          return;
        }
        switch (details.data) {
          case TabDrag():
            break;
          case PaneDrag(paneId: final moved):
            sessions.movePaneIntoRegion(moved, paneId);
        }
      },
      builder: (context, candidate, _) {
        final hovering = candidate.isNotEmpty;
        return Semantics(
          container: true,
          label: title,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: hovering
                  ? scheme.primary.withValues(alpha: 0.08)
                  : scheme.surfaceContainerLowest,
              border: Border.all(
                color: hovering || focused
                    ? scheme.primary
                    : scheme.outlineVariant,
              ),
            ),
            child: LayoutBuilder(
              builder: (context, box) => _invitation(context, box),
            ),
          ),
        );
      },
    );
  }

  /// Below this width (at 1x text) the actions are icons with tooltips: their
  /// labels would wrap a word to a line in a region this narrow.
  static const _iconsBelowWidth = 240.0;

  /// Below this height the glyph and the sentence go, so the actions and the
  /// way out stay on screen without scrolling.
  static const _plainBelowHeight = 280.0;

  static const _maxWidth = 320.0;

  Widget _invitation(BuildContext context, BoxConstraints box) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final scaler = MediaQuery.textScalerOf(context);
    final iconsOnly =
        box.maxWidth < WidthClass.scaleBreakpoint(_iconsBelowWidth, scaler);
    final plain =
        iconsOnly ||
        box.maxHeight < WidthClass.scaleBreakpoint(_plainBelowHeight, scaler);
    final width = (box.maxWidth - 2 * Insets.md).clamp(0.0, _maxWidth);

    final actions = iconsOnly
        ? [
            IconButton.filled(
              autofocus: focused,
              tooltip: 'New terminal',
              onPressed: onNewTerminal,
              icon: const Icon(AppIcons.plus),
            ),
            IconButton.filledTonal(
              tooltip: 'New agent session',
              onPressed: onNewSession,
              icon: const Icon(AppIcons.chatCircleDots),
            ),
            IconButton(
              tooltip: moveLabel,
              onPressed: onMoveTabHere,
              icon: const Icon(AppIcons.listMagnifyingGlass),
            ),
            IconButton(
              tooltip: closeLabel,
              onPressed: onClose,
              icon: const Icon(AppIcons.x),
            ),
          ]
        : [
            FilledButton.icon(
              // So a region made with Ctrl+Shift+D can be filled with Enter.
              autofocus: focused,
              onPressed: onNewTerminal,
              icon: const Icon(AppIcons.plus, size: Chrome.icon),
              label: const Text('New terminal'),
            ),
            FilledButton.tonalIcon(
              onPressed: onNewSession,
              icon: const Icon(AppIcons.chatCircleDots, size: Chrome.icon),
              // Distinct from an agent pane's default title: a fresh split must
              // not print "New session" as both content and action.
              label: const Text('New agent session'),
            ),
            // The keyboard half of the drag: a feature only reachable by
            // dragging is unreachable for some.
            TextButton.icon(
              onPressed: onMoveTabHere,
              icon: const Icon(AppIcons.listMagnifyingGlass, size: Chrome.icon),
              label: Text(moveLabel),
            ),
            TextButton(onPressed: onClose, child: Text(closeLabel)),
          ];

    return Center(
      // Vertical only: the width is capped to the region, so nothing needs to
      // scroll sideways, and a region can still be shorter than its buttons.
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Insets.md),
        child: SizedBox(
          width: width,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!plain) ...[
                Icon(
                  AppIcons.squareSplitHorizontal,
                  size: Chrome.iconHero,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(height: Insets.sm),
              ],
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurface,
                ),
              ),
              if (!plain) ...[
                const SizedBox(height: Insets.xs),
                Text(
                  // Null [accepts] is the region's rule, which takes panes; a
                  // group supplies its own and takes tabs.
                  accepts == null
                      ? 'Drag a pane here, or start something new.'
                      : 'Drag a tab here, or start something new.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: Insets.md),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: Insets.sm,
                runSpacing: Insets.xs,
                children: actions,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The **panes** that can be moved into the empty region [slotPaneId], as
/// [TabPicker] lists them — the keyboard's way to do what a drag does. Panes,
/// not tabs: a tab belongs in a workspace group's strip.
List<TabEntry> panesMovableInto(WidgetRef ref, String slotPaneId) {
  final terminals = ref.watch(terminalSessionsControllerProvider);
  final sessions = ref.read(terminalSessionsControllerProvider.notifier);
  return [
    for (final tab in terminals.tabs)
      for (final paneId in tab.layout.panes)
        if (sessions.canMovePaneIntoRegion(paneId, slotPaneId))
          TabEntry(
            item: QuickOpenItem(
              id: 'move-pane/$paneId',
              group: QuickOpenGroup.tabs,
              title: sessions.titleForPane(paneId),
              // The directory tells two `zsh` panes apart, which is why this
              // is a picker rather than a menu.
              subtitle: sessions.instanceFor(paneId)?.workingDirectory,
              icon: AppIcons.terminal,
              onSelect: () => sessions.movePaneIntoRegion(paneId, slotPaneId),
            ),
            active: false,
          ),
  ];
}

/// The tabs that can be moved into workspace group [groupId], as [TabPicker]
/// lists them — [tabsMovableInto] one level up.
List<TabEntry> tabsMovableToGroup(WidgetRef ref, String groupId) {
  final terminals = ref.watch(terminalSessionsControllerProvider);
  final sessions = ref.read(terminalSessionsControllerProvider.notifier);
  return [
    for (final tab in terminals.tabs)
      if (sessions.canMoveTabToGroup(tab.id, groupId))
        TabEntry(
          item: QuickOpenItem(
            id: 'move-tab-to-group/${tab.id}',
            group: QuickOpenGroup.tabs,
            title: sessions.titleForTab(tab.id),
            subtitle: sessions.instanceFor(tab.focusedPaneId)?.workingDirectory,
            icon: AppIcons.terminal,
            onSelect: () => sessions.moveTabToGroup(tab.id, groupId),
          ),
          active: false,
        ),
  ];
}
