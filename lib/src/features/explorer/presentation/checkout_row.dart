import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/row_menu.dart';
import '../application/session_diff_stat.dart';
import 'explorer_row.dart';
import 'session_card.dart';

/// One place a session can live: a repository, one of its worktrees, or a
/// folder the scanner has not been to yet. A single dense line, because the
/// pane's vertical space belongs to the cards.
class CheckoutRow extends StatelessWidget {
  const CheckoutRow({
    required this.depth,
    required this.icon,
    required this.title,
    required this.onTap,
    this.iconColor,
    this.subtitle,
    this.expanded,
    this.selected = false,
    this.stat,
    this.note,
    this.noteTooltip,
    this.onNewSession,
    this.newSessionTooltip = 'New session here',
    this.extraAction,
    this.menuItemsBuilder,
    this.onMenu,
    super.key,
  });

  final int depth;
  final VoidCallback onTap;
  final IconData icon;
  final Color? iconColor;
  final String title;

  /// The path relative to the project, when it says more than [title] does.
  final String? subtitle;

  /// Null draws no disclosure triangle — a row with nothing to open.
  final bool? expanded;
  final bool selected;

  /// The checkout's branch and change count, asynchronous by construction: a
  /// folder git cannot answer for shows nothing rather than an error.
  final SessionDiffStat? stat;

  /// A short clause in place of the branch — "not scanned yet".
  final String? note;
  final String? noteTooltip;

  final VoidCallback? onNewSession;
  final String newSessionTooltip;

  /// One more affordance the row needs — the rescan button on an unscanned
  /// folder.
  final Widget? extraAction;

  /// Called when the menu opens, and not before. Null for a row with no
  /// menu — see `RowMenuItemBuilder`.
  final RowMenuItemBuilder? menuItemsBuilder;
  final ValueChanged<String>? onMenu;

  /// The measured facts are dropped in order of value as the pane narrows. Two
  /// thresholds because the Explorer opens at 304px and clamps to 200 — one
  /// threshold above 304 empties the default pane's rows.
  static const _statWidth = 200.0;
  static const _branchWidth = 300.0;

  @override
  Widget build(BuildContext context) => ExplorerRow(
    kind: ExplorerRowKind.checkout,
    depth: depth,
    selected: selected,
    onTap: onTap,
    menuItemsBuilder: menuItemsBuilder,
    onMenu: onMenu,
    builder: (context) => LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return _row(
          context,
          showStat: width >= _statWidth,
          showBranch: width >= _branchWidth,
        );
      },
    ),
  );

  Widget _row(
    BuildContext context, {
    required bool showStat,
    required bool showBranch,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    final muted = density.muted(theme);
    final branch = stat?.branch;
    final onMenu = this.onMenu;

    return Row(
      children: [
        if (expanded != null)
          Icon(
            expanded! ? AppIcons.caretDown : AppIcons.caretRight,
            size: density.icon,
            color: scheme.onSurfaceVariant,
          )
        else
          SizedBox(width: density.icon),
        const SizedBox(width: 2),
        Icon(
          icon,
          size: density.icon,
          color: iconColor ?? scheme.onSurfaceVariant,
        ),
        SizedBox(width: density.glyphGap),
        // The name gets the larger share and the path is context. Both are
        // flexible, so neither can push the right-hand facts off the row.
        Flexible(
          flex: 2,
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            // The same weight a project name and a session title carry: a row
            // lighter than the cards under it had the hierarchy upside down.
            style: density.title(theme),
          ),
        ),
        if (subtitle != null) ...[
          SizedBox(width: density.glyphGap),
          Expanded(
            child: Tooltip(
              message: subtitle!,
              child: Text(
                subtitle!,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: muted,
              ),
            ),
          ),
        ] else
          const Spacer(),
        if (showStat && note != null) ...[
          SizedBox(width: density.glyphGap),
          _note(context, muted),
        ],
        if (showBranch && branch != null) ...[
          SizedBox(width: density.glyphGap),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 90),
            child: Text(
              branch,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: muted,
            ),
          ),
        ],
        if (showStat && stat != null && !stat!.isEmpty) ...[
          const SizedBox(width: Insets.sm),
          DiffStatLabel(stat: stat!),
        ],
        ?extraAction,
        if (onNewSession != null)
          ExplorerRowAction(
            tooltip: newSessionTooltip,
            icon: AppIcons.plus,
            onPressed: onNewSession,
          ),
        if (menuItemsBuilder != null && onMenu != null)
          RowMenuButton(
            tooltip: 'Folder actions',
            itemBuilder: menuItemsBuilder!,
            onSelected: onMenu,
          ),
      ],
    );
  }

  Widget _note(BuildContext context, TextStyle? muted) {
    final text = Text(note!, maxLines: 1, style: muted);
    return noteTooltip == null
        ? text
        : Tooltip(message: noteTooltip!, child: text);
  }
}
