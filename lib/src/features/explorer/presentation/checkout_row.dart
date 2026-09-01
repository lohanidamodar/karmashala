import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../application/session_diff_stat.dart';
import 'explorer_row.dart';
import 'session_card.dart';

/// One place a session can live: a repository, one of its worktrees, or a
/// folder the scanner has not been to yet.
///
/// A single dense line, because the pane's vertical space belongs to the cards.
/// It carries four things and nothing else:
///
/// ```
/// ▾ ⑂ karmashala-app   projects/karmashala-app   main  3 changed   + ⋮
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
  /// its right at all — which is what driving the app found. The indent is
  /// already spent by the time the builder runs — [ExplorerRow] draws it as the
  /// tile's own margin — so the width measured here is what the row really has.
  static const _statWidth = 200.0;
  static const _branchWidth = 300.0;

  @override
  Widget build(BuildContext context) => ExplorerRow(
    kind: ExplorerRowKind.checkout,
    depth: depth,
    selected: selected,
    onTap: onTap,
    menuItems: menuItems,
    onMenu: onMenu,
    builder: (context, menuVisible) => LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return _row(
          context,
          showStat: width >= _statWidth,
          showBranch: width >= _branchWidth,
          menuVisible: menuVisible,
        );
      },
    ),
  );

  Widget _row(
    BuildContext context, {
    required bool showStat,
    required bool showBranch,
    required bool menuVisible,
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
        // The name gets the larger share: it is what the eye is scanning
        // for, and the path beneath it is context. Both are flexible, so
        // neither can push the right-hand facts off the row.
        Flexible(
          flex: 2,
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            // The same weight a project name and a session title carry: a
            // repository row that read lighter than the cards under it had
            // the hierarchy upside down.
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
        if (menuItems.isNotEmpty && onMenu != null)
          ExplorerRowMenuButton(
            visible: menuVisible,
            tooltip: 'Folder actions',
            items: menuItems,
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
