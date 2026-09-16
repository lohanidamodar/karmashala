import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_icons.dart';
import '../design_tokens.dart';
import '../row_menu.dart';
import 'package:karmashala_session/lineage.dart';
import 'row_stats.dart';
import 'explorer_row.dart';

/// A coarse age for a card's corner: `3m`, `22m`, `7h 59m`, `2d 4h`. Under a
/// minute is "now", never "0m" — a card that counts seconds looks live.
String compactAge(Duration age) {
  if (age.isNegative || age.inMinutes < 1) return 'now';
  if (age.inHours < 1) return '${age.inMinutes}m';
  if (age.inDays < 1) {
    final minutes = age.inMinutes % 60;
    return minutes == 0 ? '${age.inHours}h' : '${age.inHours}h ${minutes}m';
  }
  final hours = age.inHours % 24;
  return hours == 0 ? '${age.inDays}d' : '${age.inDays}d ${hours}h';
}

/// A session, drawn as a three-line card: who and when, what, where. Every
/// line's right-hand slot holds exactly one fact, so the eye can read down the
/// right edge for age and then for progress.
class SessionCard extends StatelessWidget {
  const SessionCard({
    required this.depth,
    required this.selected,
    required this.agentIcon,
    required this.agentLabel,
    required this.title,
    required this.onTap,
    required this.menuItemsBuilder,
    required this.onMenu,
    this.agentColor,
    this.badge,
    this.age,
    this.ageTooltip,
    this.branch,
    this.subPath,
    this.whereabouts,
    this.whereaboutsTooltip,
    this.stat,
    this.statPending = false,
    this.worktree = false,
    this.pinned = false,
    this.link,
    this.parentTitle,
    this.lineageBroken = false,
    this.showMenu = true,
    this.selecting = false,
    this.ticked = false,
    super.key,
  });

  final int depth;
  final bool selected;

  /// Line one: what is running this, and in what colour its lifecycle is.
  final IconData agentIcon;
  final String agentLabel;
  final Color? agentColor;

  /// Live agent status, when the session has one.
  final Widget? badge;

  /// Line one, right: how long since anything was heard. Null when we have no
  /// evidence to age — which is rendered as nothing, never as `0m`.
  final String? age;

  /// What the age actually means when it is weaker than it looks — a file
  /// mtime says when the agent last *wrote*, not that anything still has it.
  final String? ageTooltip;

  final String title;

  /// Line three: the branch this session works on, when known.
  final String? branch;

  /// Line three, first: which sub-directory of the project this agent works
  /// in. On a hub of a dozen clones the repository name does not identify it.
  final String? subPath;

  /// Line three: the whereabouts clause — "opened in an external terminal",
  /// "open in another process", "last seen 2h ago".
  final String? whereabouts;
  final String? whereaboutsTooltip;

  /// Line three, right: what the checkout has produced.
  final SessionDiffStat? stat;

  /// Whether git has been asked about this checkout and has not answered yet.
  /// An empty line three is the ordinary state early in a launch and looks like
  /// a checkout with no branch, which is a claim; the ellipsis holds the space.
  final bool statPending;

  /// Whether this session runs in its own worktree — the one structural fact
  /// about a session that the branch name does not already imply.
  final bool worktree;

  final bool pinned;

  /// Why this session names another as its parent, when it does.
  final SessionLink? link;

  /// The parent's title, when that session is drawn directly above this card.
  /// Null means "from somewhere not on screen", which is what the tooltip says.
  final String? parentTitle;

  /// The parent chain could not be walked to a root. A chain that loops or is
  /// too long is *unknown*: drawing a plausible root would be a lie.
  final bool lineageBroken;

  final VoidCallback onTap;
  /// Called when the menu opens, and not before — see `RowMenuItemBuilder`. A
  /// hundred cards used to build a hundred menus per frame.
  final RowMenuItemBuilder menuItemsBuilder;
  final ValueChanged<String> onMenu;

  /// Whether the row has an overflow menu at all. The companion has no verbs
  /// to put in one, and an empty menu button is a target that does nothing.
  final bool showMenu;

  /// Whether the Explorer is asking which rows to act on: draws the tick box
  /// and makes [onTap] mean *tick*. The card is told, never decides.
  final bool selecting;

  /// Whether this row is in the selection. Ignored unless [selecting].
  final bool ticked;

  /// The glyph for a link kind — three shapes for three different facts: an
  /// agent delegated this, the user moved it, the user branched it.
  static IconData linkIcon(SessionLink link) => switch (link) {
    SessionLink.spawn => AppIcons.arrowBendDownRight,
    SessionLink.handoff => AppIcons.paperPlaneRight,
    SessionLink.fork => AppIcons.gitMerge,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // One decision — a mouse or a thumb — and every measurement below follows
    // from it. `pointer` is the Explorer's own density, unchanged.
    final density = UiDensity.of(context);
    final muted = density.muted(theme);

    // The tile, the indent, the selection rule, the right-click and the
    // keyboard menu all belong to every row kind alike; see [ExplorerRow].
    return ExplorerRow(
      kind: ExplorerRowKind.session,
      depth: depth,
      selected: selected,
      onTap: onTap,
      menuItemsBuilder: menuItemsBuilder,
      onMenu: onMenu,
      builder: (context) {
        final lines = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _SessionCardHeaderLine(
              agentIcon: agentIcon,
              agentLabel: agentLabel,
              agentColor: agentColor,
              badge: badge,
              age: age,
              ageTooltip: ageTooltip,
              muted: muted,
              density: density,
            ),
            SizedBox(height: density.lineGap),
            _SessionCardTitleLine(
              title: title,
              link: link,
              parentTitle: parentTitle,
              lineageBroken: lineageBroken,
              pinned: pinned,
              showMenu: showMenu,
              menuItemsBuilder: menuItemsBuilder,
              onMenu: onMenu,
              density: density,
            ),
            // A worktree session draws line three before git answers: the glyph
            // is a persisted fact and must not blink into existence.
            if (worktree ||
                branch != null ||
                statPending ||
                subPath != null ||
                lineageBroken ||
                whereabouts != null ||
                !(stat?.isEmpty ?? true)) ...[
              SizedBox(height: density.lineGap),
              _SessionCardWhereLine(
                subPath: subPath,
                branch: branch,
                statPending: statPending,
                whereabouts: whereabouts,
                whereaboutsTooltip: whereaboutsTooltip,
                lineageBroken: lineageBroken,
                worktree: worktree,
                stat: stat,
                muted: muted,
                density: density,
              ),
            ],
          ],
        );
        if (!selecting) return lines;
        // The box leads the whole card rather than sitting on one of its three
        // lines: it is about the row, not about anything the row says.
        return Row(
          children: [
            _tickBox(density),
            SizedBox(width: density.glyphGap),
            Expanded(child: lines),
          ],
        );
      },
    );
  }

  /// The tick, sized by density rather than by [ExplorerRow.slotOf]: a checkbox
  /// has Material's own hit area and would overflow the menu button's slot.
  Widget _tickBox(UiDensity density) => Checkbox(
    value: ticked,
    // Named so Narrator says which row it is on. The row itself is not a
    // button, so nothing else in the semantics tree carries the title here.
    semanticLabel: 'Select "$title"',
    visualDensity: density.isTouch
        ? VisualDensity.standard
        : VisualDensity.compact,
    materialTapTargetSize: density.isTouch
        ? MaterialTapTargetSize.padded
        : MaterialTapTargetSize.shrinkWrap,
    // The same callback the row's own tap runs, so ticking the box and
    // clicking the card cannot come to mean two different things.
    onChanged: (_) => onTap(),
  );
}

/// Line one: the agent, its live status and its age. The label gives way first;
/// the badge scales down and the age ellipsises only once the label is gone,
/// because the companion's labelled badge beside "active …" overflowed a 360px
/// phone at 2x text.
class _SessionCardHeaderLine extends StatelessWidget {
  const _SessionCardHeaderLine({
    required this.agentIcon,
    required this.agentLabel,
    required this.agentColor,
    required this.badge,
    required this.age,
    required this.ageTooltip,
    required this.muted,
    required this.density,
  });

  final IconData agentIcon;
  final String agentLabel;
  final Color? agentColor;
  final Widget? badge;
  final String? age;
  final String? ageTooltip;
  final TextStyle? muted;
  final UiDensity density;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final gap = density.glyphGap;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Everything but the agent's glyph may go to the right-hand facts.
        final budget = math.max(
          0.0,
          constraints.maxWidth - density.icon - gap * 2,
        );
        final badge = this.badge;
        final age = this.age;
        Widget? ageText;
        if (age != null) {
          final text = ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: math.max(
                0.0,
                badge == null ? budget - gap : (budget - gap * 2) / 2,
              ),
            ),
            child: Text(
              age,
              style: muted,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
            ),
          );
          ageText = ageTooltip == null
              ? text
              : Tooltip(message: ageTooltip!, child: text);
        }
        // One Expanded child rather than a Flexible label beside a Spacer: two
        // flex children split the free space evenly and truncated mid-word.
        return Row(
          children: [
            Expanded(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    agentIcon,
                    size: density.icon,
                    color: agentColor ?? scheme.onSurfaceVariant,
                  ),
                  SizedBox(width: gap),
                  Flexible(
                    child: Text(
                      agentLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: muted,
                    ),
                  ),
                ],
              ),
            ),
            if (badge != null || ageText != null)
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: budget),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (badge != null) ...[
                      SizedBox(width: gap),
                      // The badge is any widget, so it cannot be told to
                      // ellipsise; scaling keeps all of it legible for longer.
                      Flexible(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerRight,
                          child: badge,
                        ),
                      ),
                    ],
                    if (ageText != null) ...[SizedBox(width: gap), ageText],
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Line two: lineage, pin, the title and the menu.
class _SessionCardTitleLine extends StatelessWidget {
  const _SessionCardTitleLine({
    required this.title,
    required this.link,
    required this.parentTitle,
    required this.lineageBroken,
    required this.pinned,
    required this.showMenu,
    required this.menuItemsBuilder,
    required this.onMenu,
    required this.density,
  });

  final String title;
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
          child: Text(
            title,
            // A phone gives a long title a second line rather than ellipsising
            // the only thing that identifies the session; a dense pane cannot.
            maxLines: density.isTouch ? 2 : 1,
            overflow: TextOverflow.ellipsis,
            style: density.title(theme),
          ),
        ),
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
      ?subPath,
      ?branch,
      if (unmeasured) '…',
      ?whereabouts,
      if (lineageBroken) 'lineage cannot be established',
    ].join('  ·  ');
    // One glyph, for whichever fact leads. Two would crowd a line that is
    // already the first thing to ellipsise at the pane's minimum width.
    final leading = subPath != null
        ? AppIcons.folder
        : (branch != null || unmeasured ? AppIcons.gitBranch : null);
    final tooltip = [
      if (where.isNotEmpty) where,
      if (unmeasured) 'Branch and change counts have not been measured yet.',
      ?whereaboutsTooltip,
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

/// The progress indicator, in MonoCode's terms: `+949 −10` when line counts
/// exist, and what git can actually answer today when they do not.
class DiffStatLabel extends StatelessWidget {
  const DiffStatLabel({required this.stat, super.key});

  final SessionDiffStat stat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(letterSpacing: 0);
    final ahead = stat.commitsAhead;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (ahead != null && ahead > 0) ...[
          Text(
            '↑$ahead',
            style: style?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(width: 6),
        ],
        if (stat.hasLineCounts) ...[
          if (stat.added != null)
            Text(
              '+${stat.added}',
              style: style?.copyWith(color: semantic.diffAdded),
            ),
          if (stat.added != null && stat.removed != null)
            const SizedBox(width: 4),
          if (stat.removed != null)
            Text(
              '−${stat.removed}',
              style: style?.copyWith(color: semantic.diffRemoved),
            ),
        ] else if ((stat.changedFiles ?? 0) > 0)
          Text(
            '${stat.changedFiles} changed',
            style: style?.copyWith(color: semantic.diffAdded),
          ),
      ],
    );
  }
}
