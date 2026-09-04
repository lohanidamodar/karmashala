import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/row_menu.dart';
import '../../sessions/domain/session_lineage.dart';
import '../application/session_diff_stat.dart';
import 'explorer_row.dart';

/// A coarse age for a card's corner: `3m`, `22m`, `7h 59m`, `2d 4h`.
///
/// Deliberately not [describeAge]'s "3m ago" — a card corner has room for a
/// number and no room for a preposition, and the column position already says
/// what the number means. It keeps that function's honesty about resolution:
/// under a minute is "now", never "0m", because a card that counts seconds
/// looks live when it is not.
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

/// A session, drawn as a three-line card.
///
/// The old row was a `ListTile` with a title and a subtitle that Loop 46 kept
/// having to squeeze more into — the status, the worktree flag, the whereabouts
/// and a "last seen" age all shared half a row and were ellipsised out of
/// existence at the pane widths people actually use.
///
/// Three lines, each answering one question, is MonoCode's shape and it is the
/// right one:
///
/// * **who and when** — the agent, and how long since anything happened;
/// * **what** — the title, and nothing competing with it;
/// * **where** — the branch, what we know about the process, and what it has
///   produced.
///
/// Every line's right-hand slot holds exactly one fact, so the eye can read
/// down the right edge for age, then for progress.
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

  /// What the age actually means, when it is weaker than it looks — an
  /// imported conversation's file mtime says when the agent last *wrote*, not
  /// whether anything still has it open.
  final String? ageTooltip;

  final String title;

  /// Line three: the branch this session works on, when known.
  final String? branch;

  /// Line three, first: **which sub-directory of the project** this agent is
  /// actually working in, when it is not the project root.
  ///
  /// The owner's question, in their own words: *"if there are multiple
  /// subfolders with multiple repositories, do we know which each session is
  /// working on?"* On a hub — a project folder holding a dozen clones — the
  /// repository name alone does not answer it, and it is the first thing on the
  /// line because it is the fact that identifies the work.
  final String? subPath;

  /// Line three: Loop 46's whereabouts clause — "opened in an external
  /// terminal", "open in another process", "last seen 2h ago".
  final String? whereabouts;
  final String? whereaboutsTooltip;

  /// Line three, right: what the checkout has produced.
  final SessionDiffStat? stat;

  /// Whether this session runs in its own worktree — the one structural fact
  /// about a session that the branch name does not already imply.
  final bool worktree;

  final bool pinned;

  /// Why this session names another as its parent, when it does.
  final SessionLink? link;

  /// The parent's title, when that session is drawn directly above this card.
  /// Null means "it came from somewhere not on screen", and the glyph's tooltip
  /// says exactly that rather than naming a session the user cannot see.
  final String? parentTitle;

  /// The parent chain could not be walked to a root.
  ///
  /// Loop 54's rule: a chain that loops, or is longer than the guard allows, is
  /// **unknown** — drawing it as a tree with a plausible root would be the one
  /// lie a lineage view must not tell. The card says so in words on line three
  /// and sits at the top of its row rather than under a parent.
  final bool lineageBroken;

  final VoidCallback onTap;
  /// Called when the menu opens, and not before — see `RowMenuItemBuilder`.
  /// A hundred cards used to build a hundred menus per frame for the one
  /// that might be opened.
  final RowMenuItemBuilder menuItemsBuilder;
  final ValueChanged<String> onMenu;

  /// Whether the row has an overflow menu at all.
  ///
  /// The Explorer does, and reserves its slot on every card — though on a
  /// pointer surface the button itself only appears under the pointer or the
  /// keyboard; see [ExplorerRow]. The companion has no verbs to put in one — a
  /// phone can open a session and nothing else — and an empty menu button is a
  /// target that does nothing.
  final bool showMenu;

  /// Whether the Explorer is asking which rows to act on.
  ///
  /// Draws the tick box, and makes [onTap] mean *tick* rather than *open* —
  /// the trade taken for a mode discoverable from a toolbar button instead of
  /// hidden behind a Ctrl-click nobody guesses at. The card decides none of
  /// that; it is told, so one place owns what a click means.
  final bool selecting;

  /// Whether this row is in the selection. Ignored unless [selecting].
  final bool ticked;

  /// The glyph for a link kind. Three shapes for three genuinely different
  /// facts: an agent delegated this, the user moved it to another provider, the
  /// user branched it.
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
    // Enter on a focused card does what a click does, so the tree is navigable
    // without the mouse.
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
            _line1(context, muted, density),
            SizedBox(height: density.lineGap),
            _line2(theme, density),
            // A worktree session draws its third line even before git has
            // answered: the glyph that says "this has its own checkout" is a
            // persisted fact, and it must not blink into existence.
            if (worktree ||
                branch != null ||
                subPath != null ||
                lineageBroken ||
                whereabouts != null ||
                !(stat?.isEmpty ?? true)) ...[
              SizedBox(height: density.lineGap),
              _line3(context, muted, density),
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

  /// The tick, sized by density rather than by [ExplorerRow.slotOf]: a
  /// checkbox has Material's own hit area, and squeezing it into the menu
  /// button's slot would overflow it instead of shrinking it.
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

  Widget _line1(BuildContext context, TextStyle? muted, UiDensity density) {
    final scheme = Theme.of(context).colorScheme;
    // The left group is one Expanded child rather than a Flexible label beside
    // a Spacer: two flex children split the free space evenly, which truncated
    // "Claude Code · running" to "Claude Code · run…" with half the row empty.
    // Caught by looking at the running app, not by a test.
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
              SizedBox(width: density.glyphGap),
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
        if (badge != null) ...[SizedBox(width: density.glyphGap), badge!],
        if (age != null) ...[
          SizedBox(width: density.glyphGap),
          if (ageTooltip == null)
            Text(age!, style: muted, maxLines: 1)
          else
            Tooltip(
              message: ageTooltip!,
              child: Text(age!, style: muted, maxLines: 1),
            ),
        ],
      ],
    );
  }

  Widget _line2(ThemeData theme, UiDensity density) => Row(
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
              ? '${link!.phrase} a session that is not on this row'
              : '${link!.phrase} "$parentTitle"',
          child: Icon(
            linkIcon(link!),
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
          // the only thing that identifies the session; a dense pane cannot
          // afford one.
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

  Widget _line3(BuildContext context, TextStyle? muted, UiDensity density) {
    final scheme = Theme.of(context).colorScheme;
    final where = [
      ?subPath,
      ?branch,
      ?whereabouts,
      if (lineageBroken) 'lineage cannot be established',
    ].join('  ·  ');
    // One glyph, for whichever fact leads. Two would crowd a line that is
    // already the first thing to ellipsise at the pane's minimum width.
    final leading = subPath != null
        ? AppIcons.folder
        : (branch != null ? AppIcons.gitBranch : null);
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
        // The left half is the only thing on the card allowed to be long, so it
        // is the only thing that gives up width.
        Expanded(
          child: Tooltip(
            message: whereaboutsTooltip == null
                ? where
                : '$where\n$whereaboutsTooltip',
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
        if (stat != null && !stat!.isEmpty) ...[
          const SizedBox(width: Insets.sm),
          DiffStatLabel(stat: stat!),
        ],
      ],
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
