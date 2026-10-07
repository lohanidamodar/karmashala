import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../../explorer/application/agent_states.dart';
import '../../sessions/presentation/approval_request_card.dart';
import '../application/overview_board.dart';
import '../application/overview_providers.dart';
import '../application/overview_reads.dart';
import 'overview_quick_composer.dart';
import 'overview_session_parts.dart';

/// The frame every Overview card shares: its surface, its edge in the state
/// that matters, the keyboard's ring, and a tap that peeks.
class _CardFrame extends ConsumerWidget {
  const _CardFrame({
    required this.card,
    required this.onOpen,
    required this.child,
    this.tone,
  });

  final OverviewCard card;
  final ValueChanged<OverviewCard> onOpen;
  final Widget child;

  /// The card's surface and edge when its state asks for one.
  final (Color, Color)? tone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final selected = ref.watch(
      overviewFocusProvider.select((f) => f.selected == card.id),
    );
    final (surface, edge) = tone ?? (scheme.surfaceContainerLow, scheme.outlineVariant);
    final radius = BorderRadius.circular(Radii.lg);
    return Material(
      key: ValueKey('overview-card:${card.id}'),
      color: surface,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(
          color: selected ? scheme.primary : edge,
          width: selected ? StateLayers.focusRingWidth * 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: radius,
        onTap: () => onOpen(card),
        child: Padding(
          padding: EdgeInsets.all(
            UiDensity.of(context).isTouch ? Insets.md : Insets.md,
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Title, where it runs, and the state pill.
class _Header extends ConsumerWidget {
  const _Header({required this.card});

  final OverviewCard card;

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
          OverviewAgentRing(card: card, size: density.isTouch ? 30 : 26),
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
                  [
                    if (parent != null) '↳ $parent',
                    if (place.isNotEmpty) place,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          ...[
            const SizedBox(width: Insets.sm),
            OverviewStatePill(card: card),
          ],
        ],
      ),
    );
  }
}

/// **One session waiting on you**: what it asks, answerable here through the
/// ask path every surface uses, its plan, and a reply in words.
class OverviewQueueCard extends ConsumerWidget {
  const OverviewQueueCard({required this.card, required this.onOpen, super.key});

  final OverviewCard card;
  final ValueChanged<OverviewCard> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final failed = card.state == AgentState.failed;
    final semantic = SemanticColors.of(context);
    final tones = SurfaceTones.of(context);
    final plan = ref.watch(overviewGlanceProvider(card.id)).asData?.value?.plan;
    return _CardFrame(
      card: card,
      onOpen: onOpen,
      tone: failed
          ? (
              semantic.failureSurface,
              semantic.failure.withValues(alpha: SemanticColors.surfaceEdgeAlpha),
            )
          : (tones.attentionSurface, tones.attentionEdge),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _Header(card: card),
          const SizedBox(height: Insets.sm),
          OverviewActivityLine(card: card),
          if (!failed) ApprovalRequestCard(sessionId: card.id),
          if (plan != null) ...[
            const SizedBox(height: Insets.sm),
            OverviewPlanLine(plan: plan),
          ],
          const SizedBox(height: Insets.sm),
          OverviewQuickComposer(card: card),
        ],
      ),
    );
  }
}

/// **One session at work**: what it is doing now, its last two hours, its
/// plan, files and sub-sessions, and a quick message.
class OverviewWorkCard extends ConsumerWidget {
  const OverviewWorkCard({required this.card, required this.onOpen, super.key});

  final OverviewCard card;
  final ValueChanged<OverviewCard> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final plan = card.state == AgentState.working
        ? ref.watch(overviewGlanceProvider(card.id)).asData?.value?.plan
        : null;
    final children = card.children;
    final answer = card.state == AgentState.ready
        ? ref.watch(overviewLastAnswerProvider(card.id)).asData?.value.text
        : null;
    return _CardFrame(
      card: card,
      onOpen: onOpen,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _Header(card: card),
          const SizedBox(height: Insets.sm),
          OverviewActivityLine(card: card),
          const SizedBox(height: Insets.sm),
          OverviewActivityStrip(sessionId: card.id),
          const SizedBox(height: Insets.xs),
          Wrap(
            spacing: Insets.md,
            runSpacing: Insets.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OverviewFilesLine(sessionId: card.id),
              if (children != null)
                Text(
                  children.label,
                  key: ValueKey('overview-children:${card.id}'),
                  style: muted,
                ),
            ],
          ),
          if (plan != null) ...[
            const SizedBox(height: Insets.sm),
            OverviewPlanLine(plan: plan),
          ],
          if (answer != null) ...[
            const SizedBox(height: Insets.sm),
            _AnswerQuote(text: answer),
          ],
          const SizedBox(height: Insets.sm),
          OverviewQuickComposer(card: card),
        ],
      ),
    );
  }
}

/// The last answer's first lines, markdown marks dropped.
class _AnswerQuote extends StatelessWidget {
  const _AnswerQuote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final plain = text
        .replaceAll(RegExp(r'\*\*|__|`|^#+\s*', multiLine: true), '')
        .replaceAll(RegExp(r'\s*\n+\s*'), ' ');
    return Container(
      padding: const EdgeInsets.only(left: Insets.sm),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: scheme.outlineVariant, width: Insets.hair * 2),
        ),
      ),
      child: Text(
        plain,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
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
            OverviewAgentRing(card: card, size: 22),
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
