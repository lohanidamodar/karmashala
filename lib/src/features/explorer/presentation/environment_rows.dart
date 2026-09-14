import 'package:flutter/material.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/rows.dart' show ExplorerRow;
import 'package:karmashala_ui/tokens.dart';

import '../application/environment_terminals.dart';
import '../application/explorer_tree_nodes.dart';

/// The three folding rows above a project — machine, section, context.
///
/// They are *headers*, not tiles: only projects and sessions carry a fill, so
/// the eye reads structure and content as two different things at a glance.
class ExplorerHeaderRow extends StatelessWidget {
  const ExplorerHeaderRow({
    required this.depth,
    required this.expanded,
    required this.label,
    required this.onTap,
    this.icon,
    this.trailingText,
    this.actions = const [],
    this.emphasis = HeaderEmphasis.section,
    this.tooltip,
    super.key,
  });

  final int depth;
  final bool expanded;
  final String label;
  final VoidCallback onTap;
  final IconData? icon;

  /// The muted line on the right — a count, an age. Never a fabricated zero:
  /// pass null where nothing has been measured (§19).
  final String? trailingText;

  final List<Widget> actions;
  final HeaderEmphasis emphasis;
  final String? tooltip;

  /// The `+` and the `⋮` a project card below reserves. A header keeps the same
  /// gutter whether or not it fills it, so every count in the tree ends in one
  /// column and the `+` buttons share a centre-line.
  static const int _gutterSlots = 2;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    final slot = ExplorerRow.slotOf(density);
    final style = emphasis.style(theme)?.copyWith(
      color: emphasis == HeaderEmphasis.machine
          ? scheme.onSurface
          : scheme.onSurfaceVariant,
    );

    // Everything on the row that is not the label or the count, so the count
    // can be capped at what is left rather than at a guessed fraction.
    final fixed =
        Chrome.icon +
        Insets.xs +
        (icon == null ? 0 : Chrome.icon + Insets.xs) +
        Insets.sm * 2 +
        slot * _gutterSlots;

    final row = InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: Chrome.row + emphasis.spaceAbove,
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            Insets.xs + depth * ExplorerRow.indent,
            emphasis.spaceAbove,
            // The project rows below sit inside a tile that pads its own
            // content; a header has no tile, so it borrows the same inset or
            // its right-hand column stands 6px further out than theirs.
            Insets.xs + density.padX,
            0,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) => Row(
              children: [
                Icon(
                  expanded ? AppIcons.caretDown : AppIcons.caretRight,
                  size: Chrome.icon,
                  color: scheme.onSurfaceVariant,
                ),
                if (icon != null) ...[
                  const SizedBox(width: Insets.xs),
                  Icon(icon, size: Chrome.icon, color: scheme.onSurfaceVariant),
                ],
                const SizedBox(width: Insets.xs),
                // Tight, not `Flexible`: a loose child capped at half the free
                // width hands back what it does not use, and the remainder fell
                // off the right end as dead space behind the buttons.
                Expanded(
                  child: Text(
                    emphasis.write(label),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style,
                  ),
                ),
                if (trailingText case final String trailing) ...[
                  const SizedBox(width: Insets.sm),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: (constraints.maxWidth - fixed).clamp(
                        0.0,
                        double.infinity,
                      ),
                    ),
                    child: Text(
                      trailing,
                      maxLines: 1,
                      textAlign: TextAlign.right,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: Insets.sm),
                ...actions,
                if (actions.length < _gutterSlots)
                  SizedBox(width: slot * (_gutterSlots - actions.length)),
              ],
            ),
          ),
        ),
      ),
    );
    return tooltip == null ? row : Tooltip(message: tooltip!, child: row);
  }
}

/// Three ranks, drawn so the eye can tell them apart without reading: the
/// machine is a heading, its two sections are sub-headings under it, and a
/// context is a grouping row among the projects it holds.
enum HeaderEmphasis {
  machine,
  section,
  context;

  TextStyle? style(ThemeData theme) => switch (this) {
    HeaderEmphasis.machine => theme.textTheme.titleSmall?.copyWith(
      fontWeight: FontWeight.w700,
    ),
    // Spaced small caps, the same voice `SettingsSection` gives its own
    // titles, so a section reads as a label over a list rather than a row in
    // one.
    HeaderEmphasis.section => theme.textTheme.labelSmall?.copyWith(
      fontWeight: FontWeight.w600,
      letterSpacing: 0.8,
    ),
    HeaderEmphasis.context => theme.textTheme.labelSmall?.copyWith(
      fontWeight: FontWeight.w600,
    ),
  };

  /// A machine wants air above it; nothing else does.
  double get spaceAbove => this == HeaderEmphasis.machine ? Insets.sm : 0;

  /// `PROJECTS`, not `Projects` — a sub-heading, not a thing in the list.
  String write(String label) =>
      this == HeaderEmphasis.section ? label.toUpperCase() : label;
}

/// The glyph for a machine, by what it is rather than by what it is called.
IconData environmentGlyph(EnvironmentKind? kind) => switch (kind) {
  EnvironmentKind.ssh => AppIcons.globe,
  EnvironmentKind.wsl => AppIcons.terminalWindow,
  EnvironmentKind.windowsNative || EnvironmentKind.localPosix =>
    AppIcons.terminal,
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Insets.xs + depth * ExplorerRow.indent,
        0,
        // The same right edge as the headers above and the project tiles below.
        Insets.xs + density.padX,
        0,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: Chrome.row),
        child: Row(
          children: [
            Icon(
              terminal.running ? AppIcons.playCircle : AppIcons.checkCircle,
              size: Chrome.icon,
              color: terminal.running ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: Insets.xs),
            Expanded(
              child: Text(
                terminal.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall,
              ),
            ),
            const SizedBox(width: Insets.sm),
            if (terminal.running)
              TextButton(
                onPressed: onOpen,
                child: Text(terminal.isHosted ? 'Attach' : 'Focus'),
              ),
            if (onEnd != null)
              TextButton(
                onPressed: onEnd,
                style: TextButton.styleFrom(foregroundColor: scheme.error),
                child: const Text('End'),
              ),
          ],
        ),
      ),
    );
  }
}

/// What a machine's row says on its right.
///
/// Projects only: a folded machine has not been asked what it is running, and
/// a count nobody measured would read as "idle" (§19).
String? environmentSummary(EnvironmentNode node) => node.projectCount == 0
    ? null
    : '${node.projectCount} project${node.projectCount == 1 ? '' : 's'}';
