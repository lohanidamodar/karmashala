import 'package:flutter/material.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/environment_terminals.dart';
import '../application/explorer_tree_nodes.dart';

/// The three folding rows above a project — machine, section, context — drawn
/// in the same row model as the projects and sessions under them: one indent
/// per depth, a disclosure and a glyph column, and the right-hand column.
class ExplorerHeaderRow extends StatelessWidget {
  const ExplorerHeaderRow({
    required this.depth,
    required this.expanded,
    required this.label,
    required this.onTap,
    this.icon,
    this.trailingText,
    this.trailingTooltip,
    this.detail,
    this.action,
    this.emphasis = HeaderEmphasis.section,
    this.tooltip,
    super.key,
  });

  final int depth;
  final bool expanded;
  final String label;
  final VoidCallback onTap;
  final IconData? icon;

  /// The count in the right-hand column. Never a fabricated zero: pass null
  /// where nothing has been measured (§19).
  final String? trailingText;

  /// What the count counts, in words.
  final String? trailingTooltip;

  /// A muted clause after the label — "read 21 minutes ago" — too long for the
  /// right-hand column.
  final String? detail;

  /// The row's verb, in the `+` slot while the row is hovered or focused.
  final Widget? action;
  final HeaderEmphasis emphasis;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final row = ExplorerRow(
      kind: ExplorerRowKind.group,
      depth: depth,
      selected: false,
      onTap: onTap,
      builder: (context) {
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final density = UiDensity.of(context);
        final icon = this.icon;
        final detail = this.detail;
        final trailing = trailingText;
        return ExplorerRowLine(
          lead: ExplorerRowLead(
            expanded: expanded,
            glyph: icon == null
                ? null
                : Icon(
                    icon,
                    size: ExplorerRow.glyphSize,
                    color: scheme.onSurfaceVariant,
                  ),
          ),
          title: Row(
            children: [
              Flexible(
                child: Text(
                  emphasis.write(label),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: emphasis.style(theme, density),
                ),
              ),
              if (detail != null) ...[
                SizedBox(width: density.glyphGap),
                Expanded(
                  child: Text(
                    detail,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: density.muted(theme),
                  ),
                ),
              ],
            ],
          ),
          trailing: ExplorerRowTrailing(
            meta: trailing == null
                ? null
                : ExplorerRowMeta(trailing, tooltip: trailingTooltip),
            action: action,
          ),
        );
      },
    );
    final spaced = emphasis.spaceAbove == 0
        ? row
        : Padding(
            padding: EdgeInsets.only(top: emphasis.spaceAbove),
            child: row,
          );
    return tooltip == null ? spaced : Tooltip(message: tooltip!, child: spaced);
  }
}

/// Three ranks: the machine is a heading, its sections are group labels, and a
/// context is a row among the projects it holds.
enum HeaderEmphasis {
  machine,
  section,
  context;

  TextStyle? style(ThemeData theme, UiDensity density) => switch (this) {
    HeaderEmphasis.machine => density.rowTitle(theme, strong: true),
    HeaderEmphasis.section =>
      theme.textTheme.labelSmall
          ?.merge(Chrome.groupLabel)
          .copyWith(color: theme.colorScheme.onSurfaceVariant),
    HeaderEmphasis.context => density.rowTitle(theme),
  };

  /// A machine wants air above it; nothing else does.
  double get spaceAbove => this == HeaderEmphasis.machine ? Insets.sm : 0;

  /// `PROJECTS`, not `Projects` — a group label, not a thing in the list.
  String write(String label) =>
      this == HeaderEmphasis.section ? label.toUpperCase() : label;
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
    depth: depth,
    selected: false,
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

/// What a machine's row says, in words, when its count is hovered.
///
/// Projects only: a folded machine has not been asked what it is running, and
/// a count nobody measured would read as "idle" (§19).
String? environmentSummary(EnvironmentNode node) => node.projectCount == 0
    ? null
    : '${node.projectCount} project${node.projectCount == 1 ? '' : 's'}';
