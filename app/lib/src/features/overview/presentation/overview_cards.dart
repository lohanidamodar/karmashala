import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../../explorer/application/agent_states.dart';
import '../application/overview_board.dart';
import '../application/overview_providers.dart';
import 'overview_card_parts.dart';
import 'overview_session_parts.dart';

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
    super.key,
  });

  final OverviewCard card;
  final ValueChanged<OverviewCard>? onOpen;
  final Widget child;

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
        onTap: onOpen == null ? null : () => onOpen!(card),
        child: Padding(padding: const EdgeInsets.all(Insets.md), child: child),
      ),
    );
  }
}

/// Title, where it runs, and the state chip.
class OverviewCardHeader extends ConsumerWidget {
  const OverviewCardHeader({required this.card, this.chip, super.key});

  final OverviewCard card;

  /// In place of the state chip with its age.
  final Widget? chip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    final place = watchOverviewPlace(ref, card);
    final agent = watchOverviewAgentName(ref, card);
    final parent = card.breadcrumb;
    return Semantics(
      header: true,
      label: [
        card.entry.title,
        card.state.label,
        ?agent,
        if (place.isNotEmpty) place,
        if (parent != null) 'from $parent',
      ].join(', '),
      excludeSemantics: true,
      child: Row(
        children: [
          OverviewAgentRing(
            card: card,
            size: density.isTouch ? Insets.xl + Insets.xs : Chrome.control,
          ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  card.entry.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  parent != null ? '↳ from $parent' : place,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          OverviewNewBadge(card: card),
          const SizedBox(width: Insets.sm),
          chip ?? OverviewStatePill(card: card),
        ],
      ),
    );
  }
}

/// **One session at work**, calm: its state, what it is doing in words, the
/// latest thing it said, its plan step and diff, and its sub-sessions.
class OverviewWorkCard extends ConsumerWidget {
  const OverviewWorkCard({required this.card, required this.onOpen, super.key});

  final OverviewCard card;
  final ValueChanged<OverviewCard> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) => OverviewCardFrame(
    card: card,
    onOpen: onOpen,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        OverviewCardHeader(card: card),
        const SizedBox(height: Insets.sm),
        OverviewActivityLine(card: card),
        const SizedBox(height: Insets.xs),
        OverviewLatestMessage(sessionId: card.id),
        const SizedBox(height: Insets.xs),
        OverviewMetaLine(card: card),
        if (card.children != null) ...[
          const SizedBox(height: Insets.xs),
          OverviewSubSessions(card: card, onOpen: onOpen),
        ],
      ],
    ),
  );
}

/// One session that ended today, as a line.
class OverviewDoneRow extends ConsumerWidget {
  const OverviewDoneRow({required this.card, required this.onOpen, super.key});

  final OverviewCard card;
  final ValueChanged<OverviewCard> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final now = ref.read(clockProvider).nowUtc();
    final place = watchOverviewPlace(ref, card);
    return InkWell(
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
              child: Text.rich(
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
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
            Text(
              compactAge(now.difference(card.entry.activityAt)),
              style: theme.textTheme.labelSmall?.copyWith(color: muted),
            ),
          ],
        ),
      ),
    );
  }
}
