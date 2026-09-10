/// One terminal tab as a chip in the workbench strip, and [TabCloseScope], the
/// table its menu is built from. `terminal_panel.dart` re-exports both, so
/// nothing that reads them had to move.
library;

import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import 'package:agent_cli/descriptors.dart';
import '../domain/pane_liveness.dart';
import '../../../app/shell/workbench_tab_chip.dart';
import '../../../app/widgets/desktop_menu.dart';
import 'session_status.dart';

/// A bulk close, named the way VS Code names it. Declared in the order the menu
/// lists them, carrying all three things a row needs, so the two cannot drift.
enum TabCloseScope {
  others('Close others', AppIcons.minusCircle),
  toTheRight('Close to the right', AppIcons.caretRight),
  toTheLeft('Close to the left', AppIcons.caretLeft),
  all('Close all', AppIcons.xCircle);

  const TabCloseScope(this.label, this.icon);

  /// What the menu row says.
  final String label;

  /// What it draws in the row's leading slot.
  final IconData icon;

  /// The tabs this scope closes, for the tab at [index] of [ids].
  List<String> apply(List<String> ids, int index) => switch (this) {
    TabCloseScope.others => [
      for (var i = 0; i < ids.length; i++)
        if (i != index) ids[i],
    ],
    TabCloseScope.toTheRight => ids.sublist(index + 1),
    TabCloseScope.toTheLeft => ids.sublist(0, index),
    TabCloseScope.all => List.of(ids),
  };

  /// Whether it would close anything at all from [index] of [count] tabs — a
  /// greyed row beats a live one that silently swallows the click.
  bool closesAnything(int index, int count) => switch (this) {
    TabCloseScope.others || TabCloseScope.all => count > 1,
    TabCloseScope.toTheRight => index < count - 1,
    TabCloseScope.toTheLeft => index > 0,
  };
}

/// One terminal tab, drawn as a chip in the workbench strip.
class TerminalTabChip extends StatelessWidget {
  const TerminalTabChip({
    required this.title,
    required this.liveness,
    required this.selected,
    required this.index,
    required this.tabCount,
    required this.onTap,
    required this.onClose,
    required this.onEnd,
    required this.onBulkClose,
    this.onSavePreset,
    this.agentStatus,
    this.icon,
    this.accented = true,
    super.key,
  });

  /// The seam a cost test counts through: a status change must redraw the one
  /// chip it is about, not the strip.
  @visibleForTesting
  static int debugBuildCount = 0;

  final String title;
  final PaneLiveness liveness;

  /// What the agent in this tab is doing, or null when it holds no live agent
  /// session. Handed in rather than watched, as [liveness] is: the chip is a
  /// dumb view and `_TabChip` is what subscribes.
  final AgentActivityStatus? agentStatus;

  /// A glyph in place of the status dot, for a tab whose content is not a
  /// process: a document has no liveness, and `exited` would read as a session
  /// that died.
  final IconData? icon;

  final bool selected;

  /// Whether this is also the tab the keyboard is in: every group shows which
  /// tab it holds, only one shows where typing goes.
  final bool accented;

  /// Names and stores the whole workbench's shape. Null where a chip has no
  /// workspace behind it — a preview, or a test.
  final VoidCallback? onSavePreset;

  /// Where this tab sits in the strip, and how many there are — what a bulk row
  /// needs to know whether it would close anything. Handed in, because the
  /// strip is what knows the shape of the row it laid out.
  final int index;
  final int tabCount;

  final VoidCallback onTap;

  /// Closes the tab, leaving anything running in the background.
  final VoidCallback onClose;

  /// Ends the tab's sessions outright — only from the context menu, because
  /// the X is not a kill switch.
  final VoidCallback onEnd;

  /// Runs one of the bulk closes. Their confirmation is the strip's, not the
  /// chip's: only it can see which of those tabs still has a session running.
  final ValueChanged<TabCloseScope> onBulkClose;

  @override
  Widget build(BuildContext context) {
    debugBuildCount++;
    final status = agentStatus;
    return WorkbenchTabChip(
      selected: selected,
      accented: accented,
      onTap: onTap,
      onSecondaryTapDown: (details) => _menu(context, details.globalPosition),
      // Middle click, the same close the X performs: the session keeps running.
      onClose: onClose,
      // One slot, never two glyphs: an agent tab says what the agent is doing,
      // any other says whether anything is running, a document says what it is.
      leading: icon != null
          ? Icon(icon, size: Chrome.iconSmall)
          : status == null
          ? TabLivenessDot(liveness: liveness)
          : TabAgentStatusDot(status: status),
      label: title,
      trailing: IconButton(
        tooltip: liveness.isLive
            ? 'Close tab (the session keeps running)'
            : 'Close tab',
        iconSize: Chrome.iconSmall,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
        padding: EdgeInsets.zero,
        icon: const Icon(AppIcons.x),
        onPressed: onClose,
      ),
    );
  }

  Future<void> _menu(BuildContext context, Offset position) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final choice = await showMenu<String>(
      context: context,
      // `ContextMenuRegion._show`'s anchor. The chip keeps `showMenu`: the
      // gesture already arrives through [WorkbenchTabChip]'s `InkWell`, and the
      // strip's `Draggable` would fight a second translucent detector.
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        // Closing one tab detaches silently — a view action, and the session
        // is still in the background list. The four below clear the deck, so
        // they ask first ([confirmBulkTabClose]).
        DesktopMenuItem(value: 'close', label: 'Close tab', icon: AppIcons.x),
        for (final scope in TabCloseScope.values)
          DesktopMenuItem(
            value: scope.name,
            label: scope.label,
            icon: scope.icon,
            enabled: scope.closesAnything(index, tabCount),
          ),
        // Not about *this* tab, and here anyway: this is the menu a person
        // opens when thinking about the shape of their tabs.
        if (onSavePreset != null) ...[
          const DesktopMenuDivider(),
          DesktopMenuItem(
            value: 'save-preset',
            label: 'Save this layout as a preset…',
            icon: AppIcons.terminalWindow,
          ),
        ],
        const DesktopMenuDivider(),
        DesktopMenuItem(
          value: 'end',
          label: 'End session',
          icon: AppIcons.power,
          destructive: true,
        ),
      ],
    );
    if (choice == null) return;
    switch (choice) {
      case 'close':
        onClose();
      case 'end':
        onEnd();
      case 'save-preset':
        onSavePreset?.call();
      default:
        onBulkClose(TabCloseScope.values.byName(choice));
    }
  }
}
