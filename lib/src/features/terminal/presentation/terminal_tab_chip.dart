/// One terminal tab as a chip in the workbench strip, and the table its menu
/// is built from.
///
/// A library of its own rather than a `part` of `terminal_panel.dart`: both
/// names are public, thirteen files outside this folder already reach them,
/// and [TabCloseScope] is the chip menu's own row table — what each bulk row
/// is called, what it draws, and which tabs it takes — so the two are one
/// family. `terminal_panel.dart` re-exports them, so nothing that reads them
/// had to move.
library;

import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../agents/domain/agent_status.dart';
import '../domain/pane_liveness.dart';
import '../../../app/shell/workbench_tab_chip.dart';
import '../../../app/widgets/desktop_menu.dart';
import 'session_status.dart';

/// A bulk close, named the way VS Code names it.
///
/// Declared in the order the menu lists them, so the rows and this list cannot
/// drift apart, and carrying the three things a row needs — what it is called,
/// what it draws, and which tabs it takes — in one place rather than three.
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

  /// Whether it would close anything at all from [index] of [count] tabs.
  ///
  /// A greyed row is better than a live one that silently does nothing: "Close
  /// to the right" on the last tab has to say so rather than swallow the click.
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

  /// How many of these have been built. The seam a cost test counts through:
  /// a status change must redraw the one chip it is about, not the strip.
  @visibleForTesting
  static int debugBuildCount = 0;

  final String title;
  final PaneLiveness liveness;

  /// What the agent in this tab holds is doing, or null when the tab holds no
  /// live agent session — a plain shell, or history with nothing behind it.
  ///
  /// Handed in rather than watched, exactly as [liveness] is: the chip is a
  /// dumb view of one tab and `_TabChip` is what subscribes.
  final AgentActivityStatus? agentStatus;

  /// A glyph in place of the status dot, for a tab whose content is not a
  /// process. A document has no liveness to report and `exited` — the honest
  /// answer for a pane with no instance — would read as a session that died.
  final IconData? icon;

  final bool selected;

  /// Whether this is also the tab the keyboard is in — see
  /// [WorkbenchTabChip.accented] for the three states. Every workspace group
  /// shows which tab it holds; only one of them shows where typing goes.
  final bool accented;

  /// Names and stores the whole workbench's shape. Null where a chip has no
  /// workspace behind it to capture — a preview, or a test.
  final VoidCallback? onSavePreset;

  /// Where this tab sits in the strip, and how many there are.
  ///
  /// The two facts a bulk row needs to know whether it would close anything —
  /// handed in rather than read from a provider, because the chip is a dumb
  /// view of one tab and the strip is the thing that knows the shape of the
  /// row it laid out.
  final int index;
  final int tabCount;

  final VoidCallback onTap;

  /// Closes the tab, leaving anything running in the background.
  final VoidCallback onClose;

  /// Ends the tab's sessions outright. Only ever reached deliberately, from the
  /// tab's context menu — the X is not a kill switch.
  final VoidCallback onEnd;

  /// Runs one of the bulk closes. The confirmation those need is the strip's,
  /// not the chip's: it is the thing that can see which of the tabs it would
  /// close still has a session running.
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
      // Middle click, the same close this tab's X performs — the session keeps
      // running, exactly as that button's tooltip promises.
      onClose: onClose,
      // One slot, never two glyphs: a tab running an agent says what the agent
      // is doing, one that is not says whether anything is running at all, and
      // a document says what it is.
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
      // `ContextMenuRegion._show`'s anchor. The chip keeps `showMenu` rather
      // than that widget because the gesture already arrives through
      // [WorkbenchTabChip]'s own `InkWell`, and the strip wraps the chip in a
      // `Draggable` that a second translucent detector would fight.
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        // Closing one tab detaches, and says nothing: that is a view action,
        // and the session is still in the background list. The four below are
        // the user clearing the deck, so they ask first — see
        // [confirmBulkTabClose].
        DesktopMenuItem(value: 'close', label: 'Close tab', icon: AppIcons.x),
        for (final scope in TabCloseScope.values)
          DesktopMenuItem(
            value: scope.name,
            label: scope.label,
            icon: scope.icon,
            enabled: scope.closesAnything(index, tabCount),
          ),
        // Not about *this* tab, and here anyway. The strip's own verbs moved to
        // the title bar, and this is the menu a person opens when they are
        // thinking about the shape of their tabs — which is what a preset is.
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
