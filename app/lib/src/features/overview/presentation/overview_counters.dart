import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../explorer/application/agent_state_providers.dart';
import '../../sessions/application/session_list_prefs.dart';
import '../application/overview_board.dart';
import '../application/overview_prefs.dart';
import '../application/overview_providers.dart';

/// **The live counters**: needs you, failed, working, ready and done today,
/// each a slim toggle that shows only its own and taps again to clear.
class OverviewCounters extends ConsumerWidget {
  const OverviewCounters({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (:strip, :doneToday) = ref.watch(overviewCountersProvider);
    final filter = ref.watch(overviewPrefsProvider.select((p) => p.filter));
    final hidden = ref.watch(agentsHiddenWorkingCountProvider);
    final controller = ref.read(overviewPrefsProvider.notifier);
    final wait = strip.oldestWait;
    int count(OverviewCounter counter) => switch (counter) {
      OverviewCounter.needsYou => strip.needsYou,
      OverviewCounter.failed => strip.failed,
      OverviewCounter.working => strip.working,
      OverviewCounter.ready => strip.ready,
      OverviewCounter.done => doneToday,
    };
    return Wrap(
      key: const ValueKey('overview-counters'),
      spacing: Insets.xs,
      runSpacing: Insets.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final counter in OverviewCounter.values) ...[
          _CounterChip(
            counter: counter,
            count: count(counter),
            caption:
                counter == OverviewCounter.needsYou &&
                    wait != null &&
                    strip.needsYou > 0
                ? 'oldest ${compactAge(wait)}'
                : null,
            selected: counter.selectedIn(filter),
            onTap: () => controller.setCounter(
              counter.selectedIn(filter) ? null : counter,
            ),
          ),
          if (counter == OverviewCounter.working && hidden > 0)
            _HiddenWorking(count: hidden),
        ],
      ],
    );
  }
}

class _CounterChip extends StatelessWidget {
  const _CounterChip({
    required this.counter,
    required this.count,
    required this.selected,
    required this.onTap,
    this.caption,
  });

  final OverviewCounter counter;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final density = UiDensity.of(context);
    final live = count > 0;
    final hue = switch (counter) {
      OverviewCounter.needsYou => semantic.attention,
      OverviewCounter.failed => semantic.failure,
      OverviewCounter.working => semantic.working,
      OverviewCounter.ready => semantic.idle,
      OverviewCounter.done => scheme.onSurface,
    };
    final caption = this.caption;
    final radius = BorderRadius.circular(Radii.sm);
    return Semantics(
      button: true,
      selected: selected,
      label: [
        '${counter.label[0].toUpperCase()}${counter.label.substring(1)}, '
            '$count',
        ?caption,
        selected
            ? 'showing only these; tap to show all'
            : 'tap to show only these',
      ].join(', '),
      excludeSemantics: true,
      child: Material(
        key: ValueKey('overview-counter:${counter.name}'),
        color: selected ? StateLayers.selected(scheme) : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: selected ? scheme.primary : Colors.transparent,
            width: StateLayers.focusRingWidth,
          ),
        ),
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: density.minRow),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.sm,
                vertical: Insets.xxs,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$count',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: live ? hue : scheme.onSurfaceVariant,
                      fontWeight: live ? FontWeight.w700 : FontWeight.w400,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: Insets.xs),
                  Flexible(
                    child: Text(
                      counter.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: live
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (caption != null) ...[
                    const SizedBox(width: Insets.xs),
                    Flexible(
                      child: Text(
                        caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: hue,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "3 hidden · Show": what Hide while working took off the tiles.
class _HiddenWorking extends ConsumerWidget {
  const _HiddenWorking({required this.count});

  final int count;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: '$count working sessions hidden. Show them',
      excludeSemantics: true,
      child: InkWell(
        key: const ValueKey('overview-working-hidden'),
        borderRadius: BorderRadius.circular(Radii.sm),
        onTap: () =>
            ref.read(sessionListPrefsProvider.notifier).setHideWorking(false),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              AppIcons.eyeSlash,
              size: UiDensity.of(context).iconSmall,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: Insets.xs),
            Flexible(
              child: Text(
                '$count hidden · Show',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The small facts under the counters, each only when there is one: spend
/// an agent reported, failing checks, usage-limit hits.
class OverviewFactsLine extends ConsumerWidget {
  const OverviewFactsLine({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strip = ref.watch(overviewCountersProvider).strip;
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final muted = UiDensity.of(context).muted(theme);
    final facts = <Widget>[
      if (strip.spendRecorded)
        Tooltip(
          message:
              'What agents reported spending over their protocol (ACP), for '
              'sessions active today. CLI sessions report no cost.',
          child: Text(spendText(strip), style: muted),
        ),
      if (strip.failingChecks > 0)
        Text(
          strip.failingChecks == 1
              ? '1 failing check'
              : '${strip.failingChecks} failing checks',
          style: muted?.copyWith(color: semantic.failure),
        ),
      if (strip.usageLimitHits > 0)
        Text(
          strip.usageLimitHits == 1
              ? '1 usage limit hit'
              : '${strip.usageLimitHits} usage limit hits',
          style: muted?.copyWith(color: semantic.attention),
        ),
    ];
    if (facts.isEmpty) return const SizedBox.shrink();
    return Wrap(
      key: const ValueKey('overview-facts'),
      spacing: Insets.md,
      runSpacing: Insets.xs,
      children: facts,
    );
  }
}

/// "$0.42 today (ACP)"; only drawn when an agent reported a cost.
String spendText(OverviewStrip strip) {
  final parts = [
    for (final MapEntry(key: currency, value: amount) in strip.spend.entries)
      switch (currency) {
        'USD' => '\$${amount.toStringAsFixed(2)}',
        '' => amount.toStringAsFixed(2),
        _ => '${amount.toStringAsFixed(2)} $currency',
      },
  ];
  return '${parts.join(' + ')} today (ACP)';
}
