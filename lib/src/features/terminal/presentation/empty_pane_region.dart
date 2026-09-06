import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/quick_open/quick_open_item.dart';
import '../../../app/shell/tab_picker.dart';
import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../application/terminal_sessions_controller.dart';
import '../domain/terminal_drag.dart';
import '../domain/workspace_layout.dart';

/// A region of a split with nothing in it yet.
///
/// Splitting divides space and starts nothing (see
/// [TerminalSessionsController.splitPane]), so the new region needs a face and
/// a way to be filled. This is both: it says what it is, offers the two honest
/// ways to fill it — a new terminal, or a tab moved in — and offers to go away
/// again.
///
/// **Not a blank rectangle.** A split that opened onto nothing at all would
/// look like a bug rather than a choice, and there would be nothing to click,
/// tab to, or read out.
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

  /// The empty region's own pane id, which is also the drop target's address.
  ///
  /// An empty **workspace group** uses the same face and passes its own slot
  /// id here, with [accepts] and [onDrop] supplied: the room reads the same to
  /// a user either way, and the only real difference is what the drop is
  /// addressed to.
  final String paneId;

  /// What the room is called, in its own words.
  final String title;

  /// What the way out is called.
  final String closeLabel;

  /// Whether [drag] can land here, and what happens when it does. Null keeps
  /// the region rules — a group supplies its own.
  final bool Function(TerminalDrag drag)? accepts;
  final void Function(TerminalDrag drag)? onDrop;

  /// Whether this is the pane the active tab has focus in. Drives the focus
  /// ring, and hands the keyboard to the primary action so a split made from a
  /// chord can be filled from one.
  final bool focused;

  final VoidCallback? onNewTerminal;
  final VoidCallback? onNewSession;
  final VoidCallback? onClose;

  /// Opens the list of things that can be moved in here. `null` while there is
  /// nothing to move.
  final VoidCallback? onMoveTabHere;

  /// What that button says. A region takes panes and a group takes tabs, and
  /// the word has to be the right one — see [WorkspaceLayout].
  final String moveLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final sessions = ref.read(terminalSessionsControllerProvider.notifier);
    return DragTarget<TerminalDrag>(
      // A whole tab, or one pane out of a region's header. A tab cannot be
      // dropped into a region of itself: the tab would have to contain the very
      // region it is being put inside.
      onWillAcceptWithDetails: (details) =>
          accepts?.call(details.data) ??
          switch (details.data) {
            // A region takes **panes**. A tab carries a session, a view and a
            // status strip together and only a workspace group can host that,
            // so a tab dropped here would land in a room with no strip and no
            // bar — the shape this restructure exists to remove.
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
            child: Center(
              // A divider can be dragged until a region is a sliver of the
              // window (`kMinPaneWeight` is 5%), and buttons have a width they
              // cannot go below. So the invitation is laid out at its natural
              // width — capped, so it wraps on a wide region rather than
              // stretching — and *scrolls* on a region too small to hold it,
              // in both directions. It can then never overflow at any size.
              child: SingleChildScrollView(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.all(Insets.md),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 320),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          AppIcons.squareSplitHorizontal,
                          size: Chrome.iconHero,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: Insets.sm),
                        Text(
                          title,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: Insets.xs),
                        Text(
                          'Drag a tab here, or start something new.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: Insets.md),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: Insets.sm,
                          runSpacing: Insets.xs,
                          children: [
                            FilledButton.icon(
                              // The keyboard follows the split, so a region made
                              // with Ctrl+Shift+D can be filled with Enter.
                              autofocus: focused,
                              onPressed: onNewTerminal,
                              icon: const Icon(
                                AppIcons.plus,
                                size: Chrome.icon,
                              ),
                              label: const Text('New terminal'),
                            ),
                            FilledButton.tonalIcon(
                              onPressed: onNewSession,
                              icon: const Icon(
                                AppIcons.chatCircleDots,
                                size: Chrome.icon,
                              ),
                              // Distinct from the default title of an agent
                              // pane beside it. A fresh split must not print
                              // "New session" as both content and an action.
                              label: const Text('New agent session'),
                            ),
                            // The keyboard-reachable half of the drag. A feature
                            // you can only reach by dragging is one some people
                            // cannot reach at all.
                            TextButton.icon(
                              onPressed: onMoveTabHere,
                              icon: const Icon(
                                AppIcons.listMagnifyingGlass,
                                size: Chrome.icon,
                              ),
                              label: Text(moveLabel),
                            ),
                            TextButton(
                              onPressed: onClose,
                              child: Text(closeLabel),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The **panes** that can be moved into the empty region [slotPaneId], as
/// [TabPicker] lists them.
///
/// The keyboard's way to do what a drag does. Panes rather than tabs: a region
/// is a division inside one tab and holds panes, and a tab belongs in a
/// workspace group's strip — see [WorkspaceLayout] for the two words.
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
              // The directory tells two `zsh` panes apart, which is the whole
              // reason the picker exists rather than a menu.
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
