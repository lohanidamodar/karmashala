import 'package:flutter/material.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/environment_terminals.dart';
import 'sidebar_chrome.dart';

/// A group's label over the rows it holds — a context, a machine's terminals.
/// Flat: it stands at depth zero and indents nothing beneath it, and the list
/// pins it while its rows scroll under it. Drawn as the sidebar's group label
/// ([SidebarGroupLabel], board A2 `.grp`): 24px, small caps in the dim ink, the
/// context's colour dot before the name, the count at the right with `+` and
/// `⋮` in its place on hover — and no band or rule: the gap above it is what
/// separates it from the group before.
class ExplorerGroupHeader extends StatelessWidget {
  const ExplorerGroupHeader({
    required this.expanded,
    required this.label,
    required this.onTap,
    this.hue,
    this.spaceAbove = true,
    this.trailingText,
    this.trailingWords,
    this.detail,
    this.action,
    this.menuLabel,
    this.menuItemsBuilder,
    this.onMenu,
    this.tooltip,
    super.key,
  });

  final bool expanded;
  final String label;
  final VoidCallback onTap;

  /// The context's colour, drawn as a dot in the glyph column; null draws the
  /// column empty, so every header's label starts where a project's name does.
  final ContextHue? hue;

  /// False for the first row of a list and for the pinned copy: the band's
  /// gap is between groups, not above the list.
  final bool spaceAbove;

  /// The count in the right-hand column. Never a fabricated zero: pass null
  /// where nothing has been measured (§19).
  final String? trailingText;

  /// What the count counts, in words — `3 projects` — as its tooltip.
  final String? trailingWords;

  /// A muted clause after the label — "read 21 minutes ago" — too long for the
  /// right-hand column.
  final String? detail;

  /// The group's verb, in the `+` slot while the row is hovered or focused.
  final Widget? action;

  final String? menuLabel;
  final RowMenuItemBuilder? menuItemsBuilder;
  final ValueChanged<String>? onMenu;
  final String? tooltip;

  @override
  Widget build(BuildContext context) => SidebarGroupLabel(
    label: label,
    count: trailingText,
    countTooltip: trailingWords,
    hue: hue,
    detail: detail,
    expanded: expanded,
    onTap: onTap,
    spaceAbove: spaceAbove,
    action: action,
    menuLabel: menuLabel,
    menuItemsBuilder: menuItemsBuilder,
    onMenu: onMenu,
    tooltip: tooltip,
  );
}

/// The glyph for a machine, by what it is rather than by what it is called.
IconData environmentGlyph(EnvironmentKind? kind) => switch (kind) {
  EnvironmentKind.ssh => AppIcons.globe,
  EnvironmentKind.wsl => AppIcons.terminalWindow,
  EnvironmentKind.windowsNative ||
  EnvironmentKind.localPosix => AppIcons.terminal,
  null => AppIcons.warningCircle,
};

/// One terminal under a machine.
///
/// A hosted row can be attached to and ended; a local pane can only be
/// focused, because ending it is the pane's own close button.
class TerminalRow extends StatelessWidget {
  const TerminalRow({
    required this.terminal,
    required this.depth,
    required this.onOpen,
    this.onEnd,
    super.key,
  });

  final EnvironmentTerminal terminal;
  final int depth;
  final VoidCallback onOpen;
  final VoidCallback? onEnd;

  @override
  Widget build(BuildContext context) => ExplorerRow(
    kind: ExplorerRowKind.terminal,
    minHeight: Sidebar.rowHeight,
    depth: depth,
    selected: false,
    // The row is its own first verb, as a session's is — which is also what
    // makes it a stop the arrow keys can land on.
    onTap: terminal.running ? onOpen : null,
    builder: (context) {
      final theme = Theme.of(context);
      final scheme = theme.colorScheme;
      final density = UiDensity.of(context);
      return LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            ExplorerRowLead(
              glyph: Icon(
                terminal.running ? AppIcons.playCircle : AppIcons.checkCircle,
                size: ExplorerRow.glyphSize,
                color: terminal.running
                    ? scheme.primary
                    : scheme.onSurfaceVariant,
              ),
            ),
            Expanded(
              child: Text(
                terminal.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: density.rowTitle(theme),
              ),
            ),
            const SizedBox(width: Insets.sm),
            // Scaled rather than clipped when large text meets a narrow pane.
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth / 2),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (terminal.running)
                      TextButton(
                        onPressed: onOpen,
                        child: Text(terminal.isHosted ? 'Attach' : 'Focus'),
                      ),
                    if (onEnd != null)
                      TextButton(
                        onPressed: onEnd,
                        style: TextButton.styleFrom(
                          foregroundColor: scheme.error,
                        ),
                        child: const Text('End'),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// `3 projects`, `1 project`.
String projectCountWords(int count) => '$count project${count == 1 ? '' : 's'}';
