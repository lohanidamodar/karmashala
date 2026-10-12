import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/widgets/truncated_text.dart';
import '../../../core/util/clock_provider.dart';
import '../../explorer/application/agent_states.dart';
import '../application/overview_board.dart';
import '../application/overview_providers.dart';
import 'overview_batch_bar.dart';
import 'overview_card_parts.dart';
import 'overview_end_button.dart';
import 'overview_resume_actions.dart';
import 'overview_session_parts.dart';
import 'overview_title_block.dart';

/// The edge a card of [state] is drawn with: colour only where the owner is
/// wanted, on the border and never the surface.
Color overviewCardEdge(BuildContext context, AgentState state) {
  final semantic = SemanticColors.of(context);
  return switch (state) {
    AgentState.needsYou => semantic.attention.withValues(
      alpha: SemanticColors.surfaceEdgeAlpha,
    ),
    AgentState.failed => semantic.failure.withValues(
      alpha: SemanticColors.surfaceEdgeAlpha,
    ),
    _ => Theme.of(context).colorScheme.outlineVariant,
  };
}

/// The frame every Overview card shares: one surface, its edge in the state
/// that matters, the keyboard's ring, and a tap that peeks.
class OverviewCardFrame extends ConsumerWidget {
  const OverviewCardFrame({
    required this.card,
    required this.onOpen,
    required this.child,
    this.leading = 0,
    super.key,
  });

  final OverviewCard card;
  final ValueChanged<OverviewCard>? onOpen;
  final Widget child;

  /// Room at the start for what sits over the card's edge: the tree's avatar.
  final double leading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final selected = ref.watch(
      overviewFocusProvider.select((f) => f.selected == card.id),
    );
    final radius = BorderRadius.circular(Radii.lg);
    return Material(
      key: ValueKey('overview-card:${card.id}'),
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(
          color: selected
              ? scheme.primary
              : overviewCardEdge(context, card.state),
          width: selected ? StateLayers.focusRingWidth * 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: radius,
        onTap: onOpen == null
            ? null
            : () {
                if (!overviewPickSelects(ref, card, touch: _touch(context))) {
                  onOpen!(card);
                }
              },
        onLongPress: () => overviewPickSelects(ref, card, long: true),
        // A right-click opens the card's ⋯ where the pointer is.
        onSecondaryTapUp: (details) => showOverviewCardMenu(
          context,
          ref,
          card,
          at: details.globalPosition,
        ),
        // Hovered or holding the keys, the card shows its End.
        child: OverviewHoverScope(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              Insets.md + leading,
              Insets.md,
              Insets.md,
              Insets.md,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

bool _touch(BuildContext context) => UiDensity.of(context).isTouch;

/// Title, where it runs, and the state chip.
class OverviewCardHeader extends ConsumerWidget {
  const OverviewCardHeader({
    required this.card,
    this.chip,
    this.ring = true,
    super.key,
  });

  final OverviewCard card;

  /// In place of the state chip with its age.
  final Widget? chip;

  /// The agent's ring before the title; off where an avatar says it.
  final bool ring;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    final place = watchOverviewCardPlace(ref, card);
    final agent = watchOverviewAgentName(ref, card);
    final parent = card.breadcrumb;
    final titleStyle = theme.textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w600,
    );
    return Row(
      children: [
        OverviewSelectBox(card: card),
        if (ring) ...[
          OverviewAgentRing(
            card: card,
            size: density.isTouch ? Insets.xl + Insets.xs : Chrome.control,
          ),
          const SizedBox(width: Insets.sm),
        ],
        Expanded(
          child: OverviewTitleBlock(
            titleFloor: overviewTitleFloor(
              context,
              card.entry.title,
              titleStyle,
            ),
            title: Semantics(
              header: true,
              label: [
                card.entry.title,
                card.state.label,
                ?agent,
                if (place.isNotEmpty) place,
                if (parent != null) 'from $parent',
              ].join(', '),
              excludeSemantics: true,
              // A long press selects the card; hover names it whole.
              child: TruncatedText(
                card.entry.title,
                textKey: ValueKey('overview-card-title:${card.id}'),
                triggerMode: TooltipTriggerMode.manual,
                style: titleStyle,
              ),
            ),
            meta: parent != null || place.isNotEmpty
                ? _ParentChip(
                    // A sub-session's card: a tap peeks its parent.
                    parentId: card.parentId,
                    childId: card.id,
                    child: ExcludeSemantics(
                      child: Text(
                        // A header is never drawn under its parent — the
                        // tree draws a pill there — so it says where it
                        // came from.
                        parent == null ? place : '↳ from $parent',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  )
                : null,
            // The menu and End stay their own buttons; the state is in the
            // title's label.
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OverviewNewBadge(card: card),
                const SizedBox(width: Insets.sm),
                Flexible(
                  child: ExcludeSemantics(
                    child: chip ?? OverviewStatePill(card: card),
                  ),
                ),
                OverviewEndButton(card: card),
                OverviewCardMenu(card: card),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// [child], the header's "↳ parent": with a [parentId], a tap peeks it.
class _ParentChip extends ConsumerWidget {
  const _ParentChip({
    required this.parentId,
    required this.childId,
    required this.child,
  });

  final String? parentId;
  final String childId;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parent = parentId;
    if (parent == null) return child;
    return Semantics(
      button: true,
      label: 'Peek the parent session',
      child: InkWell(
        key: ValueKey('overview-parent-chip:$childId'),
        borderRadius: BorderRadius.circular(Radii.sm),
        onTap: () => ref.read(overviewFocusProvider.notifier).peek(parent),
        child: child,
      ),
    );
  }
}

/// **One session at work**, calm: its state, what it is doing in words, the
/// latest thing it said, its plan step and diff, and — as a family's root on
/// the tree — its [footer].
class OverviewWorkCard extends ConsumerWidget {
  const OverviewWorkCard({
    required this.card,
    required this.onOpen,
    this.leading = 0,
    this.footer,
    super.key,
  });

  final OverviewCard card;
  final ValueChanged<OverviewCard> onOpen;

  /// See [OverviewCardFrame.leading]; with it, the avatar names the agent.
  final double leading;
  final Widget? footer;

  @override
  Widget build(BuildContext context, WidgetRef ref) => OverviewCardFrame(
    card: card,
    onOpen: onOpen,
    leading: leading,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        OverviewCardHeader(card: card, ring: leading == 0),
        const SizedBox(height: Insets.sm),
        if (card.waitingOn != null)
          OverviewWaitingOnLine(card: card)
        else
          OverviewActivityLine(card: card),
        const SizedBox(height: Insets.xs),
        OverviewLatestMessage(sessionId: card.id),
        const SizedBox(height: Insets.xs),
        OverviewMetaLine(card: card),
        OverviewUsageLine(sessionId: card.id),
        if (footer case final footer?) ...[
          const SizedBox(height: Insets.xs),
          footer,
        ],
      ],
    ),
  );
}

/// One session that ended today, as a line.
class OverviewDoneRow extends ConsumerWidget {
  const OverviewDoneRow({
    required this.card,
    required this.onOpen,
    this.depth = 0,
    super.key,
  });

  final OverviewCard card;
  final ValueChanged<OverviewCard> onOpen;

  /// How many of its ancestors ended today too, above it.
  final int depth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final now = ref.read(clockProvider).nowUtc();
    final place = watchOverviewCardPlace(ref, card);
    final row = InkWell(
      key: ValueKey('overview-done:${card.id}'),
      borderRadius: BorderRadius.circular(Radii.sm),
      onTap: () => onOpen(card),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.xs,
          vertical: Insets.xs,
        ),
        child: Row(
          children: [
            OverviewAgentRing(card: card, size: Insets.xl - Insets.xxs),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: OverviewTitleBlock(
                titleFloor: overviewTitleFloor(
                  context,
                  card.entry.title,
                  theme.textTheme.bodySmall,
                ),
                title: TruncatedText.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: card.entry.title),
                      if (place.isNotEmpty)
                        TextSpan(
                          text: '  $place',
                          style: TextStyle(color: muted),
                        ),
                    ],
                  ),
                  textKey: ValueKey('overview-card-title:${card.id}'),
                  style: theme.textTheme.bodySmall,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      compactAge(now.difference(card.entry.activityAt)),
                      style: theme.textTheme.labelSmall?.copyWith(color: muted),
                    ),
                    OverviewEndButton(card: card),
                    OverviewCardMenu(card: card),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
    // A sub-session that ended with its parent sits under it, a step in.
    return Padding(
      padding: EdgeInsets.only(left: Insets.lg * depth),
      child: OverviewHoverScope(child: row),
    );
  }
}
