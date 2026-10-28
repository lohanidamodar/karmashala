import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/widgets/truncated_text.dart';
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
    this.compact = false,
    this.bare = false,
    super.key,
  });

  final OverviewCard card;
  final ValueChanged<OverviewCard>? onOpen;
  final Widget child;

  /// Room at the start for what sits over the card's edge: the tree's avatar.
  final double leading;

  /// A phone's card: padded a step tighter.
  final bool compact;

  /// No surface or edge of its own, inside a frame that already draws them:
  /// a family's root on a phone. The keyboard's ring still shows.
  final bool bare;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final selected = ref.watch(
      overviewFocusProvider.select((f) => f.selected == card.id),
    );
    final radius = BorderRadius.circular(Radii.lg);
    final pad = compact ? Insets.sm : Insets.md;
    return Material(
      key: ValueKey('overview-card:${card.id}'),
      color: bare ? Colors.transparent : scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: selected
            ? BorderSide(
                color: scheme.primary,
                width: StateLayers.focusRingWidth * 2,
              )
            : bare
            ? BorderSide.none
            : BorderSide(color: overviewCardEdge(context, card.state)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: radius,
        // A tap always opens: only the pick box picks.
        onTap: onOpen == null ? null : () => onOpen!(card),
        // A long press is a thumb's right-click: the card's ⋯.
        onLongPress: () => showOverviewCardMenu(context, ref, card),
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
            padding: EdgeInsets.fromLTRB(pad + leading, pad, pad, pad),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Title, where it runs, and the state chip.
class OverviewCardHeader extends ConsumerWidget {
  const OverviewCardHeader({
    required this.card,
    this.chip,
    this.ring = true,
    this.pick = true,
    this.stacked = false,
    super.key,
  });

  final OverviewCard card;

  /// In place of the state chip with its age.
  final Widget? chip;

  /// The agent's ring before the title; off where an avatar says it.
  final bool ring;

  /// The pick box before the title; off where the avatar's face carries it.
  final bool pick;

  /// The state, End and ⋯ on a row of their own under the title, from its
  /// start: a phone's tree root, whose title keeps the width.
  final bool stacked;

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
    final state = ExcludeSemantics(
      child: chip ?? OverviewStatePill(card: card),
    );
    final head = Row(
      children: [
        if (pick) OverviewSelectBox(card: card),
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
              // A long press opens the card's menu; hover names it whole.
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
            trailing: stacked
                ? const SizedBox.shrink()
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      OverviewNewBadge(card: card),
                      const SizedBox(width: Insets.sm),
                      Flexible(child: state),
                      OverviewEndButton(card: card),
                      OverviewCardMenu(card: card),
                    ],
                  ),
          ),
        ),
      ],
    );
    if (!stacked) return head;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        head,
        Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(child: state),
                  const SizedBox(width: Insets.xs),
                  OverviewNewBadge(card: card),
                ],
              ),
            ),
            OverviewEndButton(card: card),
            OverviewCardMenu(card: card),
          ],
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
