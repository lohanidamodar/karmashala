import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:agent_cli/usage.dart' show kUsageCriticalPercent;
import 'package:karmashala_ui/charts.dart' show formatCompactCount;
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../../agents/presentation/usage_chip.dart' show formatUsageDuration;

import '../../explorer/application/agent_states.dart';
import '../../explorer/application/session_diff_stat.dart';
import '../application/overview_board.dart';
import '../application/overview_providers.dart';
import '../application/overview_reads.dart';
import '../application/overview_seen.dart';
import '../application/overview_usage.dart';
import 'overview_batch_bar.dart';
import 'overview_resume_actions.dart';
import 'overview_session_parts.dart';

/// [text] as one plain paragraph: markdown marks and line breaks dropped.
String overviewPlain(String text) => text
    .replaceAll(RegExp(r'\*\*|__|`|^#+\s*', multiLine: true), '')
    .replaceAll(RegExp(r'\s*\n+\s*'), ' ')
    .trim();

/// **The latest thing the agent said**, two lines, lit briefly when it
/// changes so a card that moved catches the eye.
class OverviewLatestMessage extends ConsumerStatefulWidget {
  const OverviewLatestMessage({required this.sessionId, super.key});

  final String sessionId;

  @override
  ConsumerState<OverviewLatestMessage> createState() =>
      _OverviewLatestMessageState();
}

class _OverviewLatestMessageState extends ConsumerState<OverviewLatestMessage> {
  var _flashes = 0;

  @override
  Widget build(BuildContext context) {
    final provider = overviewLastAnswerProvider(widget.sessionId);
    ref.listen(provider, (before, after) {
      final was = before?.value?.text;
      final now = after.value?.text;
      if (was != null && now != null && now != was) {
        setState(() => _flashes++);
      }
    });
    // `.value` keeps the last answer on screen while the next one is read.
    final text = ref.watch(provider).value?.text;
    if (text == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final lit = theme.colorScheme.primary;
    final motion = Motion.of(context);
    return TweenAnimationBuilder<double>(
      key: ValueKey(_flashes),
      tween: Tween(begin: _flashes == 0 || !motion.animate ? 0 : 1, end: 0),
      duration: motion.statusPeriod,
      curve: Motion.standard,
      builder: (context, t, child) => DecoratedBox(
        decoration: BoxDecoration(
          color: lit.withValues(alpha: StateLayers.selectedAlpha * t),
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        child: child,
      ),
      child: Text(
        overviewPlain(text),
        key: ValueKey('overview-last:${widget.sessionId}'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
    );
  }
}

/// "2/4 · Write the layout tests" and "+620 −40 · 3 files", each only when
/// known.
class OverviewMetaLine extends ConsumerWidget {
  const OverviewMetaLine({required this.card, super.key});

  final OverviewCard card;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = card.id;
    final reads =
        card.state == AgentState.working ||
        card.state == AgentState.needsYou ||
        card.state == AgentState.quiet ||
        card.state == AgentState.ready;
    final plan = reads
        ? ref.watch(overviewGlanceProvider(id)).asData?.value?.plan
        : null;
    final files = ref.watch(overviewChangedFilesProvider(id)).asData?.value;
    final stat = card.entry.native == null
        ? null
        : ref.watch(sessionDiffStatProvider(id)).value;
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final fileCount = files?.length ?? stat?.changedFiles;
    final added = stat?.added;
    final removed = stat?.removed;
    final step = plan == null || plan.total == 0
        ? null
        : '${plan.doneCount}/${plan.total}'
              '${plan.isFinished
                  ? ' · done'
                  : plan.current == null
                  ? ''
                  : ' · ${plan.current!.text}'}';
    final diff = <InlineSpan>[
      if (added != null)
        TextSpan(
          text: '+$added',
          style: TextStyle(color: semantic.diffAdded),
        ),
      if (added != null && removed != null) const TextSpan(text: ' '),
      if (removed != null)
        TextSpan(
          text: '−$removed',
          style: TextStyle(color: semantic.diffRemoved),
        ),
      if (fileCount != null && fileCount > 0) ...[
        if (added != null || removed != null) const TextSpan(text: ' · '),
        TextSpan(text: fileCount == 1 ? '1 file' : '$fileCount files'),
      ],
    ];
    if (step == null && diff.isEmpty) return const SizedBox.shrink();
    return Row(
      key: ValueKey('overview-meta:$id'),
      children: [
        if (step != null)
          Flexible(
            child: Text(
              step,
              key: ValueKey('overview-step:$id'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: muted,
            ),
          ),
        if (step != null && diff.isNotEmpty) const SizedBox(width: Insets.md),
        if (diff.isNotEmpty)
          Text.rich(
            TextSpan(children: diff),
            key: ValueKey('overview-diff:$id'),
            maxLines: 1,
            style: muted,
          ),
      ],
    );
  }
}

/// A parent's sub-sessions on its card: a summary line, the [limit] most
/// urgent, and "+N more", which opens the parent.
class OverviewSubSessions extends ConsumerWidget {
  const OverviewSubSessions({
    required this.card,
    required this.onOpen,
    this.limit = 3,
    super.key,
  });

  final OverviewCard card;
  final ValueChanged<OverviewCard> onOpen;
  final int limit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final children = ref.watch(
      overviewBoardProvider.select((b) => b.children[card.id]),
    );
    if (children == null || children.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final ordered = byUrgency(children);
    final shown = ordered.take(limit).toList();
    final more = ordered.length - shown.length;
    return Container(
      key: ValueKey('overview-subs:${card.id}'),
      padding: const EdgeInsets.only(top: Insets.xs),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            subSessionSummary(children),
            key: ValueKey('overview-children:${card.id}'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: muted,
          ),
          for (final child in shown)
            OverviewSubSessionRow(card: child, onOpen: onOpen),
          if (more > 0)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: ValueKey('overview-subs-more:${card.id}'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
                  textStyle: theme.textTheme.labelSmall,
                ),
                onPressed: () => onOpen(card),
                child: Text('+$more more'),
              ),
            ),
        ],
      ),
    );
  }
}

/// One sub-session as a line: its state, its title and its chip.
class OverviewSubSessionRow extends StatelessWidget {
  const OverviewSubSessionRow({
    required this.card,
    required this.onOpen,
    super.key,
  });

  final OverviewCard card;
  final ValueChanged<OverviewCard> onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    return InkWell(
      key: ValueKey('overview-sub:${card.id}'),
      borderRadius: BorderRadius.circular(Radii.sm),
      onTap: () => onOpen(card),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.xxs,
          vertical: Insets.xxs,
        ),
        child: Row(
          children: [
            OverviewStateGlyph(
              state: card.state,
              size: density.iconSmall + Insets.hair,
            ),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: Text(
                card.entry.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
            const SizedBox(width: Insets.sm),
            OverviewStateChip(state: card.state),
          ],
        ),
      ),
    );
  }
}

/// "3": what came since the owner last opened [card] on this device, from the
/// read its card already makes. Nothing for one never opened here.
class OverviewNewBadge extends ConsumerWidget {
  const OverviewNewBadge({required this.card, super.key});

  final OverviewCard card;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = card.id;
    final seen = ref.watch(overviewSeenProvider.select((s) => s[id]));
    if (seen == null || card.state == AgentState.ended) {
      return const SizedBox.shrink();
    }
    final peeked = ref.watch(
      overviewFocusProvider.select((f) => f.peeked == id),
    );
    final times =
        ref.watch(overviewGlanceProvider(id)).asData?.value?.messageTimes ??
        const <DateTime>[];
    final count = newSince(seen, times) ?? 0;
    if (peeked || count == 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Tooltip(
      message: '$count new since you last looked',
      child: Container(
        key: ValueKey('overview-new:$id'),
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.xs + Insets.xxs,
          vertical: Insets.hair,
        ),
        decoration: BoxDecoration(
          color: scheme.primary,
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Text(
          '$count',
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

/// **One session as the phone lists it**: two lines — its title with what is
/// new and its state, then what it is doing — opening its peek on a tap.
class OverviewPhoneRow extends ConsumerWidget {
  const OverviewPhoneRow({required this.card, required this.onOpen, super.key});

  final OverviewCard card;
  final ValueChanged<OverviewCard> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selected = ref.watch(
      overviewFocusProvider.select((f) => f.selected == card.id),
    );
    final line = watchOverviewLine(ref, card);
    final edge = switch (card.state) {
      AgentState.needsYou => SemanticColors.of(context).attention,
      AgentState.failed => SemanticColors.of(context).failure,
      _ => null,
    };
    return Material(
      color: selected ? StateLayers.selected(scheme) : Colors.transparent,
      child: InkWell(
        key: ValueKey('overview-phone-row:${card.id}'),
        onTap: () {
          if (!overviewPickSelects(ref, card, touch: true)) onOpen(card);
        },
        onLongPress: () => overviewPickSelects(ref, card, long: true),
        child: Container(
          constraints: const BoxConstraints(minHeight: Touch.target),
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.xs,
            vertical: Insets.sm,
          ),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: scheme.outlineVariant),
              left: edge == null
                  ? BorderSide.none
                  : BorderSide(color: edge, width: Insets.xxs),
            ),
          ),
          child: Row(
            children: [
              OverviewSelectBox(card: card),
              OverviewAgentRing(card: card, size: Insets.xl + Insets.xs),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            card.entry.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        OverviewNewBadge(card: card),
                        const SizedBox(width: Insets.xs),
                        // At large text it ends before the row does.
                        Flexible(child: OverviewStatePill(card: card)),
                        OverviewCardMenu(card: card),
                      ],
                    ),
                    Text(
                      line,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "1.2M tokens · $0.42" as reported, or "Usage not recorded"; never a
/// figure worked out here.
String overviewUsageText(OverviewUsage usage) {
  if (!usage.recorded) return 'Usage not recorded';
  final tokens = usage.tokens;
  final cost = usage.cost;
  return [
    tokens == null
        ? 'tokens not recorded'
        : '${formatCompactCount(tokens)} tokens',
    if (cost != null)
      switch (cost.currency?.trim() ?? '') {
        'USD' => '\$${cost.amount.toStringAsFixed(2)}',
        '' => cost.amount.toStringAsFixed(2),
        final currency => '${cost.amount.toStringAsFixed(2)} $currency',
      },
  ].join(' · ');
}

/// "5h limit 92% · resets in 12 min": the account's own reading.
String overviewLimitText(OverviewLimit limit, DateTime now) {
  final reset = limit.resetsAt;
  return [
    '${limit.label} limit ${limit.percent.round()}%',
    if (reset != null)
      'resets in ${formatUsageDuration(reset.difference(now))}',
  ].join(' · ');
}

/// **What a session has used**, and a warning when its account is near a
/// limit. Says nothing until the counts have been read.
class OverviewUsageLine extends ConsumerWidget {
  const OverviewUsageLine({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usage = ref.watch(overviewUsageProvider(sessionId));
    final limit = ref.watch(overviewLimitProvider(sessionId));
    if (!usage.read && limit == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final small = theme.textTheme.labelSmall?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (usage.read)
          Text(
            overviewUsageText(usage),
            key: ValueKey('overview-usage:$sessionId'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: small?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        if (limit != null)
          Text(
            overviewLimitText(limit, ref.read(clockProvider).nowUtc()),
            key: ValueKey('overview-limit:$sessionId'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: small?.copyWith(
              color: limit.percent >= kUsageCriticalPercent
                  ? semantic.failure
                  : semantic.attention,
              fontWeight: FontWeight.w600,
            ),
          ),
      ],
    );
  }
}
