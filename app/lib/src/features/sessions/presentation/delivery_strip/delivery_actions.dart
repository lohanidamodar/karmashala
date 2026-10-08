// Action chips, the Ship menu and the bar actions, with their icons.

part of '../delivery_strip.dart';

/// One action above the conversation's composer: a Material chip, at the scale
/// of the message column it belongs to.
class _ActionChip extends StatelessWidget {
  const _ActionChip({required this.offered, required this.onPressed});

  final OfferedAction offered;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final action = offered.action;
    // The primary action keeps its weight and its container in either host —
    // which of these to press next is the one thing the strip is saying.
    final chip = ActionChip(
      avatar: Icon(_actionIcon(action), size: Chrome.iconAction),
      label: Text(action.label),
      backgroundColor: offered.isPrimary && offered.isEnabled
          ? theme.colorScheme.primaryContainer
          : null,
      labelStyle: offered.isPrimary
          ? theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w600,
              color: offered.isEnabled
                  ? theme.colorScheme.onPrimaryContainer
                  : theme.colorScheme.onSurfaceVariant,
            )
          : null,
      onPressed: onPressed,
    );
    return Tooltip(message: _actionTooltip(offered), child: chip);
  }
}

/// One verb behind **Ship ▾**; a null [onPressed] is drawn disabled.
class _ShipEntry {
  const _ShipEntry({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
}

/// **Ship ▾**: the delivery verbs that are not the next one, in one menu.
class _ShipMenu extends StatelessWidget {
  const _ShipMenu({required this.entries});

  final List<_ShipEntry> entries;

  @override
  Widget build(BuildContext context) => Builder(
    builder: (anchor) => _BarAction(
      icon: AppIcons.rocketLaunch,
      label: 'Ship ▾',
      tooltip: 'Review, checks, pull request and handing the session on',
      onPressed: () async {
        final picked = await showDesktopMenuUnder<int>(anchor, [
          for (final (index, entry) in entries.indexed)
            DesktopMenuItem(
              value: index,
              label: entry.label,
              icon: entry.icon,
              enabled: entry.onPressed != null,
            ),
        ]);
        if (picked != null) entries[picked].onPressed?.call();
      },
    ),
  );
}

/// The vertical padding every control on the session bar's action row draws
/// with, so all three are the same height at 100% text and at 200%.
const double kBarControlPad = 3;

/// One action as the session bar draws it: the bar's own pill. **One weight,
/// one primary**, and disabled is drawn rather than hidden.
class _BarAction extends StatelessWidget {
  const _BarAction({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onPressed,
    this.primary = false,
    this.compact = false,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool primary;

  /// Glyph only — see [DeliveryStrip.compact].
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = onPressed != null;
    // The mockup's pill: a hairline and no fill. The primary is the accent's
    // ink, not a container — a filled button in a 30px status line shouted
    // over the pane. One that cannot be pressed keeps its weight only.
    final accent = primary && enabled;
    final foreground = !enabled
        ? scheme.onSurfaceVariant
        : accent
        ? scheme.primary
        : scheme.onSurface;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: label,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(Radii.sm),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.sm,
              vertical: kBarControlPad,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Radii.sm),
              // The same box either way, so promoting an action moves nothing
              // beside it.
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: Chrome.iconSmall, color: foreground),
                if (!compact) ...[
                  const SizedBox(width: Insets.xs),
                  // Flexible so a pill wider than the room left ellipsises: at
                  // 200% text "Archive worktree" is wider than the gap.
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: foreground,
                        fontWeight: primary ? FontWeight.w600 : null,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What a delivery action says on hover: why it cannot be pressed, or what
/// pressing it does. One answer, so the two hosts cannot disagree.
String _actionTooltip(OfferedAction offered) {
  final reason = offered.disabledReason;
  if (reason != null) return reason;
  final prompt = offered.prompt;
  return prompt == null
      ? _appActionTooltip(offered.action)
      : 'Asks the agent: “$prompt”';
}

String _appActionTooltip(DeliveryAction action) => switch (action) {
  DeliveryAction.viewPullRequest => 'Opens the pull request in your browser',
  DeliveryAction.viewChecks => 'Opens the checks in your browser',
  DeliveryAction.updateFromBase =>
    'Merges the base branch into this one. Refuses if the tree is dirty, an '
        'agent is running, or the merge would conflict.',
  DeliveryAction.markReady => 'Takes the pull request out of draft',
  DeliveryAction.archive =>
    'Removes the worktree directory. The session, its transcript, review '
        'notes and checkpoints are kept.',
  _ => '',
};

IconData _actionIcon(DeliveryAction action) => switch (action) {
  DeliveryAction.commit => AppIcons.check,
  DeliveryAction.push => AppIcons.arrowUp,
  DeliveryAction.openPullRequest => AppIcons.gitMerge,
  DeliveryAction.viewPullRequest => AppIcons.arrowSquareOut,
  DeliveryAction.viewChecks => AppIcons.checkCircle,
  DeliveryAction.resolveConflicts => AppIcons.warningCircle,
  DeliveryAction.updateFromBase => AppIcons.arrowsClockwise,
  DeliveryAction.addressRequestedChanges => AppIcons.listMagnifyingGlass,
  DeliveryAction.resolveReviewComments => AppIcons.listMagnifyingGlass,
  DeliveryAction.markReady => AppIcons.arrowSquareOut,
  DeliveryAction.merge => AppIcons.gitMerge,
  DeliveryAction.runTests => AppIcons.play,
  DeliveryAction.archive => AppIcons.trash,
};

IconData _stageIcon(DeliveryStage stage) => switch (stage) {
  DeliveryStage.working => AppIcons.pencilSimple,
  DeliveryStage.committed => AppIcons.check,
  DeliveryStage.pushed => AppIcons.arrowUp,
  DeliveryStage.prOpen => AppIcons.gitMerge,
  DeliveryStage.checksPassing => AppIcons.checkCircle,
  DeliveryStage.checksFailing => AppIcons.warningCircle,
  DeliveryStage.merged => AppIcons.gitMerge,
  DeliveryStage.archived => AppIcons.folder,
};
