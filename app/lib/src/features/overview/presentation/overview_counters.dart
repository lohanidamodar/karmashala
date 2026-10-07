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
import '../application/overview_tiles.dart';

/// **The live counters**: Needs you, Working, Ready and Done today, each a
/// chip that filters the cards to its state, and taps again to clear.
class OverviewCounters extends ConsumerWidget {
  const OverviewCounters({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (:strip, :doneToday) = ref.watch(overviewCountersProvider);
    final columns = ref.watch(
      overviewPrefsProvider.select((p) => p.filter.columns),
    );
    final hidden = ref.watch(agentsHiddenWorkingCountProvider);
    final controller = ref.read(overviewPrefsProvider.notifier);
    final wait = strip.oldestWait;
    final needs = strip.needsYou + strip.failed;
    final counters = [
      _Counter(
        column: BoardColumn.needsYou,
        count: needs,
        caption: [
          if (wait != null && strip.needsYou > 0) 'oldest ${compactAge(wait)}',
          if (strip.failed > 0) '${strip.failed} failed',
        ].join(' · '),
      ),
      _Counter(column: BoardColumn.working, count: strip.working),
      _Counter(column: BoardColumn.ready, count: strip.ready),
      _Counter(column: BoardColumn.done, count: doneToday),
    ];
    Widget tile(_Counter counter) => _CounterTile(
      counter: counter,
      selected: columns?.contains(counter.column) ?? false,
      hiddenWorking: counter.column == BoardColumn.working ? hidden : 0,
      onTap: () =>
          controller.setColumns(counterTapped(columns, counter.column)),
    );
    return Wrap(
      key: const ValueKey('overview-counters'),
      spacing: Insets.sm,
      runSpacing: Insets.sm,
      children: [for (final counter in counters) tile(counter)],
    );
  }
}

class _Counter {
  const _Counter({required this.column, required this.count, this.caption});

  final BoardColumn column;
  final int count;
  final String? caption;

  String get label => switch (column) {
    BoardColumn.done => 'Done today',
    _ => column.label,
  };
}

class _CounterTile extends ConsumerWidget {
  const _CounterTile({
    required this.counter,
    required this.selected,
    required this.hiddenWorking,
    required this.onTap,
  });

  final _Counter counter;
  final bool selected;
  final int hiddenWorking;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final density = UiDensity.of(context);
    final count = counter.count;
    final live = count > 0;
    final hue = switch (counter.column) {
      BoardColumn.needsYou => semantic.attention,
      BoardColumn.working => semantic.working,
      BoardColumn.ready => semantic.idle,
      BoardColumn.done => scheme.onSurface,
    };
    final ink = live ? hue : scheme.onSurfaceVariant;
    final glyphSize = density.icon;
    final glyph = switch (counter.column) {
      BoardColumn.needsYou when live => AskGlyph(size: glyphSize),
      BoardColumn.needsYou => Icon(
        AppIcons.shield,
        size: glyphSize,
        color: ink,
      ),
      BoardColumn.working when live => WorkingSpinner(
        size: glyphSize,
        color: hue,
      ),
      BoardColumn.working => Icon(AppIcons.circle, size: glyphSize, color: ink),
      BoardColumn.ready => Icon(
        AppIcons.checkCircle,
        size: glyphSize,
        color: ink,
      ),
      BoardColumn.done => Icon(
        AppIcons.listChecks,
        size: glyphSize,
        color: scheme.onSurfaceVariant,
      ),
    };
    final caption = counter.caption;
    final spoken = [
      counter.label,
      '$count',
      if (caption != null && caption.isNotEmpty) caption,
      selected
          ? 'showing only these; tap to show all'
          : 'tap to show only these',
    ].join(', ');
    final radius = BorderRadius.circular(Radii.lg);
    // An ask waiting is the one counter that should catch the eye unasked.
    final asking = live && counter.column == BoardColumn.needsYou;
    final tones = SurfaceTones.of(context);
    final rest = asking ? tones.attentionSurface : scheme.surfaceContainerLow;
    return Material(
      key: ValueKey('overview-counter:${counter.column.name}'),
      color: selected
          ? Color.alphaBlend(StateLayers.selected(scheme), rest)
          : rest,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(
          color: selected
              ? scheme.primary
              : asking
              ? tones.attentionEdge
              : scheme.outlineVariant,
          width: selected ? StateLayers.focusRingWidth * 2 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.md,
            vertical: Insets.sm,
          ),
          child: Wrap(
            spacing: Insets.sm,
            runSpacing: Insets.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Semantics(
                button: true,
                selected: selected,
                label: spoken,
                excludeSemantics: true,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    glyph,
                    const SizedBox(width: Insets.sm),
                    Text(
                      '$count',
                      maxLines: 1,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: live ? ink : scheme.onSurfaceVariant,
                        fontWeight: live ? FontWeight.w700 : FontWeight.w400,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: Insets.xs),
                    Flexible(
                      child: Text(
                        counter.label.toLowerCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: live
                              ? scheme.onSurface
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (caption != null && caption.isNotEmpty) ...[
                      const SizedBox(width: Insets.sm),
                      Flexible(
                        child: Text(
                        caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: density
                            .muted(theme)
                            ?.copyWith(
                              color: counter.column == BoardColumn.needsYou
                                  ? hue
                                  : null,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                        ),
                      ),
                    ],
                    if (selected) ...[
                      const SizedBox(width: Insets.xs),
                      Icon(
                        AppIcons.funnelFill,
                        size: density.iconSmall,
                        color: scheme.primary,
                      ),
                    ],
                  ],
                ),
              ),
              if (hiddenWorking > 0) _HiddenWorking(count: hiddenWorking),
            ],
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
