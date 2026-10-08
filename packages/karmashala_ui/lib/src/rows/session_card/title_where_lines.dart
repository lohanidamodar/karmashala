// The session card's title line and where line.

part of '../session_card.dart';

/// Line two: lineage, pin, the title and the menu.
class _SessionCardTitleLine extends StatelessWidget {
  const _SessionCardTitleLine({
    required this.title,
    required this.details,
    required this.link,
    required this.parentTitle,
    required this.lineageBroken,
    required this.pinned,
    required this.runningBelow,
    required this.showMenu,
    required this.menuItemsBuilder,
    required this.onMenu,
    required this.density,
  });

  final Widget? runningBelow;
  final String title;

  /// [SessionCard.pointerDetails]: the whole title, the agent and where it
  /// runs, on a long-press (or a hover) of the title.
  final String details;
  final SessionLink? link;
  final String? parentTitle;
  final bool lineageBroken;
  final bool pinned;
  final bool showMenu;
  final RowMenuItemBuilder menuItemsBuilder;
  final ValueChanged<String> onMenu;
  final UiDensity density;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final link = this.link;
    final titleText = Text(
      title,
      // A phone gives a long title a second line rather than ellipsising
      // the only thing that identifies the session; a dense pane cannot.
      maxLines: density.isTouch ? 2 : 1,
      overflow: TextOverflow.ellipsis,
      style: density.title(theme),
    );
    return Row(
      children: [
        if (lineageBroken) ...[
          Tooltip(
            message:
                'Lineage cannot be established — this session names a parent '
                'whose chain does not terminate, so it is drawn on its own '
                'rather than under a tree we cannot vouch for.',
            child: Icon(
              AppIcons.question,
              size: density.iconSmall,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          SizedBox(width: density.glyphGap),
        ] else if (link != null) ...[
          Tooltip(
            message: parentTitle == null
                ? '${link.phrase} a session that is not on this row'
                : '${link.phrase} "$parentTitle"',
            child: Icon(
              SessionCard.linkIcon(link),
              size: density.iconSmall,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          SizedBox(width: density.glyphGap),
        ],
        if (pinned) ...[
          Icon(
            AppIcons.pushPinFill,
            size: density.iconSmall,
            color: theme.colorScheme.primary,
          ),
          SizedBox(width: density.glyphGap),
        ],
        Expanded(
          child: details.isEmpty
              ? titleText
              : Tooltip(message: details, child: titleText),
        ),
        if (runningBelow case final badge?) ...[
          SizedBox(width: density.glyphGap),
          badge,
        ],
        if (showMenu)
          RowMenuButton(
            tooltip: 'Session actions',
            itemBuilder: menuItemsBuilder,
            onSelected: onMenu,
          ),
      ],
    );
  }
}

/// Line three: where the session works, and what it has produced.
class _SessionCardWhereLine extends StatelessWidget {
  const _SessionCardWhereLine({
    required this.subPath,
    required this.branch,
    required this.statPending,
    required this.whereabouts,
    required this.whereaboutsTooltip,
    required this.scheduled,
    required this.scheduledTooltip,
    required this.lineageBroken,
    required this.worktree,
    required this.stat,
    required this.muted,
    required this.density,
  });

  final String? subPath;
  final String? branch;
  final bool statPending;
  final String? whereabouts;
  final String? whereaboutsTooltip;
  final String? scheduled;
  final String? scheduledTooltip;
  final bool lineageBroken;
  final bool worktree;
  final SessionDiffStat? stat;
  final TextStyle? muted;
  final UiDensity density;

  /// The most of the line the diff stat may take before it scales down, so a
  /// `+12949 −10310 ↑14` never ellipsises the branch to nothing.
  static const _statShare = 0.6;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // The ellipsis stands in for the branch and only for the branch: a branch
    // name means the checkout was measured, so the two never share the line.
    final unmeasured = statPending && branch == null;
    final where = [
      ?scheduled,
      ?subPath,
      ?branch,
      if (unmeasured) '…',
      ?whereabouts,
      if (lineageBroken) 'lineage cannot be established',
    ].join('  ·  ');
    // One glyph, for whichever fact leads. Two would crowd a line that is
    // already the first thing to ellipsise at the pane's minimum width.
    final leading = scheduled != null
        ? AppIcons.clock
        : subPath != null
        ? AppIcons.folder
        : (branch != null || unmeasured ? AppIcons.gitBranch : null);
    final tooltip = [
      if (where.isNotEmpty) where,
      if (unmeasured) 'Branch and change counts have not been measured yet.',
      ?whereaboutsTooltip,
      ?scheduledTooltip,
    ].join('\n');
    final stat = this.stat;
    final showStat = stat != null && !stat.isEmpty;
    return LayoutBuilder(
      builder: (context, constraints) {
        final fixed =
            (leading != null ? density.iconSmall + density.glyphGap : 0) +
            (worktree ? density.glyphGap + density.iconSmall : 0) +
            (showStat ? Insets.sm : 0);
        final free = math.max(0.0, constraints.maxWidth - fixed);
        return Row(
          children: [
            if (leading != null) ...[
              Icon(
                leading,
                size: density.iconSmall,
                color: scheme.onSurfaceVariant,
              ),
              SizedBox(width: density.glyphGap),
            ],
            // The left half is the only thing on the card allowed to be long,
            // so it is the first thing that gives up width.
            Expanded(
              child: Tooltip(
                message: tooltip,
                child: Text(
                  where,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: muted,
                ),
              ),
            ),
            if (worktree) ...[
              SizedBox(width: density.glyphGap),
              Tooltip(
                message: 'Runs in its own worktree',
                child: Icon(
                  AppIcons.treeStructure,
                  size: density.iconSmall,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            if (showStat) ...[
              const SizedBox(width: Insets.sm),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: where.isEmpty ? free : free * _statShare,
                ),
                // Scaled, never ellipsised: half a line count is a wrong one.
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: DiffStatLabel(stat: stat),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
