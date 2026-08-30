import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../application/session_diff_stat.dart';

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

/// Right-click support, shared by every row in the Explorer.
class ContextMenuRegion extends StatelessWidget {
  const ContextMenuRegion({
    required this.menuItems,
    required this.onSelected,
    required this.child,
    super.key,
  });

  final List<PopupMenuEntry<String>> menuItems;
  final ValueChanged<String> onSelected;
  final Widget child;

  Future<void> _show(BuildContext context, Offset position) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: menuItems,
    );
    if (selected != null) onSelected(selected);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onSecondaryTapDown: (details) => _show(context, details.globalPosition),
    child: child,
  );
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
    required this.menuItems,
    required this.onMenu,
    this.agentColor,
    this.badge,
    this.age,
    this.ageTooltip,
    this.branch,
    this.whereabouts,
    this.whereaboutsTooltip,
    this.stat,
    this.worktree = false,
    this.pinned = false,
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
  final VoidCallback onTap;
  final List<PopupMenuEntry<String>> menuItems;
  final ValueChanged<String> onMenu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
      letterSpacing: 0,
    );

    return ContextMenuRegion(
      menuItems: menuItems,
      onSelected: onMenu,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: selected
                ? scheme.primary.withValues(alpha: 0.10)
                : Colors.transparent,
            border: Border(
              // Selection is carried by a rule in the accent, as on the
              // workbench tabs: an outline is invisible against a neutral ramp.
              left: BorderSide(
                color: selected ? scheme.primary : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          padding: EdgeInsets.fromLTRB(6.0 + depth * 14, 6, 4, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _line1(context, muted),
              const SizedBox(height: 2),
              _line2(theme),
              // A worktree session draws its third line even before git has
              // answered: the glyph that says "this has its own checkout" is a
              // persisted fact, and it must not blink into existence.
              if (worktree ||
                  branch != null ||
                  whereabouts != null ||
                  !(stat?.isEmpty ?? true)) ...[
                const SizedBox(height: 3),
                _line3(context, muted),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _line1(BuildContext context, TextStyle? muted) {
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
                size: Chrome.iconSmall,
                color: agentColor ?? scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 5),
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
        if (badge != null) ...[const SizedBox(width: 6), badge!],
        if (age != null) ...[
          const SizedBox(width: 6),
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

  Widget _line2(ThemeData theme) => Row(
    children: [
      if (pinned) ...[
        Icon(AppIcons.pushPinFill, size: 11, color: theme.colorScheme.primary),
        const SizedBox(width: 4),
      ],
      Expanded(
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      SizedBox(
        width: 22,
        height: 18,
        child: PopupMenuButton<String>(
          tooltip: 'Session actions',
          padding: EdgeInsets.zero,
          iconSize: 15,
          icon: const Icon(AppIcons.dotsThreeVertical),
          onSelected: onMenu,
          itemBuilder: (context) => menuItems,
        ),
      ),
    ],
  );

  Widget _line3(BuildContext context, TextStyle? muted) {
    final scheme = Theme.of(context).colorScheme;
    final where = [?branch, ?whereabouts].join('  ·  ');
    return Row(
      children: [
        if (branch != null) ...[
          Icon(AppIcons.gitBranch, size: 11, color: scheme.onSurfaceVariant),
          const SizedBox(width: 4),
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
          const SizedBox(width: 6),
          Tooltip(
            message: 'Runs in its own worktree',
            child: Icon(
              AppIcons.treeStructure,
              size: 11,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
        if (stat != null && !stat!.isEmpty) ...[
          const SizedBox(width: 8),
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
