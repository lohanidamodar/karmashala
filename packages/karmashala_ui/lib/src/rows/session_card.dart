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

/// A session. Under a pointer, one line (spec §2.4); under a thumb, a
/// three-line card: who and when, what, where. Every
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
    this.agentMark,
    this.agentName,
    this.environment,
    this.badge,
    this.age,
    this.ageTooltip,
    this.branch,
    this.subPath,
    this.whereabouts,
    this.whereaboutsTooltip,
    this.scheduled,
    this.scheduledTooltip,
    this.stat,
    this.statPending = false,
    this.worktree = false,
    this.pinned = false,
    this.link,
    this.parentTitle,
    this.lineageBroken = false,
    this.showMenu = true,
    this.action,
    this.selecting = false,
    this.ticked = false,
    this.statusLabel,
    this.unread = false,
    this.needsYou = false,
    this.settled = false,
    this.tickEnabled = true,
    this.tickDisabledTooltip,
    super.key,
  });

  /// Whether this row may join the selection as it stands. See
  /// [ExplorerRowTick].
  final bool tickEnabled;
  final String? tickDisabledTooltip;

  /// What [agentIcon] means, for its tooltip and screen reader, when it is the
  /// row's status glyph.
  final String? statusLabel;

  /// Finished while nobody was looking: the title is set strong.
  final bool unread;

  /// Waiting on the user: the title is set strong.
  final bool needsYou;

  /// Ended and seen: the row is dimmed. Never while it is selected.
  final bool settled;

  final int depth;
  final bool selected;

  /// Line one: what is running this, and in what colour its lifecycle is.
  final IconData agentIcon;
  final String agentLabel;
  final Color? agentColor;

  /// The agent's own mark (its logo), drawn just before the title under a
  /// pointer so a one-line row still says whose session it is — the lead glyph
  /// there is the status, not the agent. Decorative: [agentName] is its words.
  final Widget? agentMark;

  /// The agent's name, for [agentMark]'s tooltip and screen reader.
  final String? agentName;

  /// Where the session runs — "Windows", a WSL distribution, an SSH host —
  /// said only on the title's hover.
  final String? environment;

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

  /// What is due to happen to this session and when — `resumes 14:05` — drawn
  /// first on the meta line behind a clock, so a narrow row keeps it.
  final String? scheduled;
  final String? scheduledTooltip;

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

  /// A row-level verb in the slot left of the menu, shown with it on hover or
  /// focus — the session rows' × (End session). Pointer rows only.
  final Widget? action;

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

    // The fill, the indent, the right-click and the keyboard menu belong to
    // every row kind alike; see [ExplorerRow].
    return ExplorerRow(
      kind: ExplorerRowKind.session,
      depth: depth,
      selected: selected,
      // The same amber the Sessions lens gives a waiting row (board N1).
      needsYou: needsYou,
      settled: settled && !selected,
      onTap: onTap,
      menuItemsBuilder: menuItemsBuilder,
      onMenu: onMenu,
      builder: (context) {
        if (!density.isTouch) return _pointerBody(context, density, muted);
        final lines = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _SessionCardHeaderLine(
              agentIcon: agentIcon,
              agentLabel: agentLabel,
              agentColor: agentColor,
              agentMark: agentMark,
              agentName: agentName,
              statusLabel: statusLabel,
              badge: badge,
              age: age,
              ageTooltip: ageTooltip,
              muted: muted,
              density: density,
            ),
            SizedBox(height: density.lineGap),
            _SessionCardTitleLine(
              title: title,
              details: pointerDetails,
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
                scheduled: scheduled,
                scheduledTooltip: scheduledTooltip,
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

  /// Under a pointer, one line (spec §2.4, 28 px): status glyph, title, pin,
  /// age and the menu. What the card's other lines said under a thumb —
  /// agent, branch, whereabouts, what the checkout has produced, where it
  /// works, what it came from — is the title's hover, in those words.
  Widget _pointerBody(
    BuildContext context,
    UiDensity density,
    TextStyle? muted,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final badge = this.badge;
    final Widget glyph;
    if (badge != null) {
      glyph = badge;
    } else if (unread) {
      glyph = Tooltip(
        message: 'Finished — not seen yet',
        child: Icon(
          AppIcons.circleFill,
          size: density.iconSmall,
          color: semantic.unread,
          semanticLabel: 'Finished, not seen yet',
        ),
      );
    } else {
      final icon = Icon(
        agentIcon,
        size: ExplorerRow.glyphSize,
        color: agentColor ?? scheme.onSurfaceVariant,
        semanticLabel: statusLabel,
      );
      glyph = statusLabel == null
          ? icon
          : Tooltip(message: statusLabel!, child: icon);
    }
    final age = this.age;
    final Widget? ageText = age == null
        ? null
        : ExplorerRowMeta(age, tooltip: ageTooltip);

    final lead = ExplorerRowLead(
      glyph: glyph,
      tick: selecting ? _tickBox(density) : null,
    );
    final details = pointerDetails;
    final titleText = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: density.rowTitle(theme, strong: unread || needsYou),
    );
    final agentMark = this.agentMark;
    return ExplorerRowLine(
      lead: lead,
      title: Row(
        children: [
          if (agentMark != null) ...[
            Tooltip(
              message: agentName ?? '',
              child: Semantics(
                label: agentName,
                child: SizedBox.square(
                  dimension: ExplorerRow.glyphSize,
                  child: Center(child: agentMark),
                ),
              ),
            ),
            SizedBox(width: density.glyphGap),
          ],
          Flexible(
            child: details.isEmpty
                ? titleText
                : Tooltip(
                    message: details,
                    waitDuration: const Duration(milliseconds: 400),
                    child: titleText,
                  ),
          ),
          if (pinned) ...[
            SizedBox(width: density.glyphGap),
            Icon(
              AppIcons.pushPinFill,
              size: density.iconSmall,
              color: scheme.primary,
              semanticLabel: 'Pinned',
            ),
          ],
        ],
      ),
      trailing: ExplorerRowTrailing(
        meta: ageText,
        action: action,
        menu: showMenu
            ? RowMenuButton(
                tooltip: 'Session actions',
                itemBuilder: menuItemsBuilder,
                onSelected: onMenu,
              )
            : null,
      ),
    );
  }

  /// What a pointer row no longer draws, said on the title's hover: the whole
  /// title first (the row ellipsises it) and where it runs, then one clause
  /// per line, in the words the card's second and third lines used.
  String get pointerDetails {
    final unmeasured = statPending && branch == null;
    final stat = this.stat;
    final link = this.link;
    return [
      title,
      ?environment,
      [
        ?scheduled,
        agentLabel,
        ?branch,
        ?whereabouts,
      ].where((clause) => clause.isNotEmpty).join('  ·  '),
      if (stat != null && !stat.isEmpty) diffStatWords(stat),
      if (worktree) 'Runs in its own worktree',
      if (subPath case final subPath?) 'In $subPath',
      if (lineageBroken)
        'Lineage cannot be established — this session names a parent whose '
            'chain does not terminate, so it is drawn on its own.'
      else if (link != null)
        parentTitle == null
            ? '${link.phrase} a session that is not on this row'
            : '${link.phrase} "$parentTitle"',
      if (unmeasured) 'Branch and change counts have not been measured yet.',
      ?whereaboutsTooltip,
      ?scheduledTooltip,
    ].where((line) => line.isNotEmpty).join('\n');
  }

  /// The tick, sized by density rather than by [ExplorerRow.slotOf]: a checkbox
  /// has Material's own hit area and would overflow the menu button's slot.
  Widget _tickBox(UiDensity density) => ExplorerRowTick(
    value: ticked,
    // Named so Narrator says which row it is on. The row itself is not a
    // button, so nothing else in the semantics tree carries the title here.
    semanticLabel: 'Select "$title"',
    // The same callback the row's own tap runs, so ticking the box and
    // clicking the card cannot come to mean two different things.
    onChanged: tickEnabled ? onTap : null,
    disabledTooltip: tickDisabledTooltip,
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
    required this.agentMark,
    required this.agentName,
    required this.statusLabel,
    required this.badge,
    required this.age,
    required this.ageTooltip,
    required this.muted,
    required this.density,
  });

  final IconData agentIcon;
  final String agentLabel;
  final Color? agentColor;

  /// With a mark, the agent is its logo and never its name in text; the
  /// words are the logo's tooltip and the title's long-press.
  final Widget? agentMark;
  final String? agentName;
  final String? statusLabel;
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
        // Everything but the agent's glyphs may go to the right-hand facts.
        final glyphs = agentMark == null
            ? density.icon
            : density.icon * 2 + gap;
        final budget = math.max(0.0, constraints.maxWidth - glyphs - gap * 2);
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
                  if (statusLabel case final status?)
                    Tooltip(
                      message: status,
                      child: Icon(
                        agentIcon,
                        size: density.icon,
                        color: agentColor ?? scheme.onSurfaceVariant,
                        semanticLabel: status,
                      ),
                    )
                  else
                    Icon(
                      agentIcon,
                      size: density.icon,
                      color: agentColor ?? scheme.onSurfaceVariant,
                    ),
                  SizedBox(width: gap),
                  if (agentMark case final mark?)
                    Tooltip(
                      message: agentName ?? '',
                      child: Semantics(
                        label: agentName,
                        child: SizedBox.square(
                          dimension: density.icon,
                          child: Center(child: mark),
                        ),
                      ),
                    )
                  else
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
    required this.details,
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

/// [DiffStatLabel]'s facts in words, for a hover: `↑2  +949 −10`.
String diffStatWords(SessionDiffStat stat) {
  final ahead = stat.commitsAhead;
  return [
    if (ahead != null && ahead > 0) '↑$ahead',
    if (stat.hasLineCounts)
      [
        if (stat.added != null) '+${stat.added}',
        if (stat.removed != null) '−${stat.removed}',
      ].join(' ')
    else if ((stat.changedFiles ?? 0) > 0)
      '${stat.changedFiles} changed',
  ].join('  ');
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
