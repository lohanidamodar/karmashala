import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/widgets/desktop_menu.dart';
import '../../../app/theme/design_tokens.dart';
import '../application/session_diff_stat.dart';
import 'session_card.dart';

/// One place a session can live: a repository, one of its worktrees, or a
/// folder the scanner has not been to yet.
///
/// A single dense line, because the pane's vertical space belongs to the cards.
/// It carries four things and nothing else:
///
/// ```
/// ▾ ⑂ chitragupta-app   projects/chitragupta-app   main  3 changed   + ⋮
/// ```
///
/// * **what it is** — the glyph says repository, worktree, or unscanned folder;
/// * **where it is** — the name, and the path relative to the project when that
///   is not simply the name. On a hub project this is the answer to the owner's
///   question: which sub-directory is this;
/// * **what git says** — branch and change count, from the checkout provider the
///   cards beneath share, so a row costs no `git status` of its own;
/// * **what you can do** — start a session here, or open the menu.
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
    this.menuItems = const [],
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

  /// The checkout's branch and change count. Asynchronous by construction: the
  /// row draws without it and fills in when git answers, and a folder git cannot
  /// answer for shows nothing rather than an error.
  final SessionDiffStat? stat;

  /// A short clause in place of the branch — "not scanned yet".
  final String? note;
  final String? noteTooltip;

  final VoidCallback? onNewSession;
  final String newSessionTooltip;

  /// One more affordance the row needs — the rescan button on an unscanned
  /// folder.
  final Widget? extraAction;

  final List<PopupMenuEntry<String>> menuItems;
  final ValueChanged<String>? onMenu;

  /// The measured facts are dropped in order of value as the pane narrows,
  /// rather than all at once: the change count answers "is there work here",
  /// which is what the row is scanned for, and the branch is on every card
  /// beneath it anyway.
  ///
  /// **The Explorer opens at 304px** and clamps to 200, so a single threshold
  /// above 304 means the default pane shows a repository row with nothing on
  /// its right at all — which is what driving the app found. Depth counts
  /// against the budget because indentation does: a worktree row two levels in
  /// has 28px less to spend than the repository above it.
  static const _statWidth = 200.0;
  static const _branchWidth = 300.0;

  @override
  Widget build(BuildContext context) {
    final row = LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth - depth * 14;
        return _row(
          context,
          showStat: width >= _statWidth,
          showBranch: width >= _branchWidth,
        );
      },
    );
    final onMenu = this.onMenu;
    if (menuItems.isEmpty || onMenu == null) return row;
    return ContextMenuRegion(
      menuItems: menuItems,
      onSelected: onMenu,
      child: row,
    );
  }

  Widget _row(
    BuildContext context, {
    required bool showStat,
    required bool showBranch,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
      letterSpacing: 0,
    );
    final branch = stat?.branch;

    return InkWell(
      onTap: onTap,
      focusColor: scheme.primary.withValues(alpha: 0.12),
      child: Container(
        constraints: const BoxConstraints(minHeight: Chrome.row),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: 0.08)
              : Colors.transparent,
          border: Border(
            left: BorderSide(
              color: selected ? scheme.primary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        padding: EdgeInsets.fromLTRB(4.0 + depth * 14, 2, 4, 2),
        child: Row(
          children: [
            if (expanded != null)
              Icon(
                expanded! ? AppIcons.caretDown : AppIcons.caretRight,
                size: 14,
                color: scheme.onSurfaceVariant,
              )
            else
              const SizedBox(width: 14),
            const SizedBox(width: 2),
            Icon(
              icon,
              size: Chrome.iconSmall,
              color: iconColor ?? scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            // The name gets the larger share: it is what the eye is scanning
            // for, and the path beneath it is context. Both are flexible, so
            // neither can push the right-hand facts off the row.
            Flexible(
              flex: 2,
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(width: 6),
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
              const SizedBox(width: 6),
              _note(context, muted),
            ],
            if (showBranch && branch != null) ...[
              const SizedBox(width: 6),
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
              const SizedBox(width: 8),
              DiffStatLabel(stat: stat!),
            ],
            ?extraAction,
            if (onNewSession != null)
              IconButton(
                tooltip: newSessionTooltip,
                visualDensity: VisualDensity.compact,
                iconSize: 14,
                constraints: const BoxConstraints.tightFor(
                  width: 22,
                  height: 20,
                ),
                padding: EdgeInsets.zero,
                icon: const Icon(AppIcons.plus),
                onPressed: onNewSession,
              ),
            if (menuItems.isNotEmpty && onMenu != null)
              SizedBox(
                width: 20,
                height: 20,
                child: PopupMenuButton<String>(
                  tooltip: 'Folder actions',
                  padding: EdgeInsets.zero,
                  iconSize: 14,
                  icon: const Icon(AppIcons.dotsThreeVertical),
                  onSelected: onMenu,
                  itemBuilder: (context) => menuItems,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _note(BuildContext context, TextStyle? muted) {
    final text = Text(note!, maxLines: 1, style: muted);
    return noteTooltip == null
        ? text
        : Tooltip(message: noteTooltip!, child: text);
  }
}
