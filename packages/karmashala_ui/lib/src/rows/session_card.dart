import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_icons.dart';
import '../design_tokens.dart';
import '../row_menu.dart';
import 'package:karmashala_session/lineage.dart';
import 'row_stats.dart';
import 'explorer_row.dart';

part 'session_card/diff_stat.dart';
part 'session_card/header_line.dart';
part 'session_card/title_where_lines.dart';

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
    this.runningBelow,
    super.key,
  });

  /// After the title: its sub-sessions still at work ([RunningBelowBadge]).
  final Widget? runningBelow;

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
              runningBelow: runningBelow,
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
                : Tooltip(message: details, child: titleText),
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
          if (runningBelow case final badge?) ...[
            SizedBox(width: density.glyphGap),
            badge,
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
