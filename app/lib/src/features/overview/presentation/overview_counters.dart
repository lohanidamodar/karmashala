import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show kLaunchSlotRule;
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../../explorer/application/agent_state_providers.dart';
import '../../sessions/application/capacity_providers.dart';
import '../../sessions/application/session_list_prefs.dart';
import '../application/overview_board.dart';
import '../application/overview_prefs.dart';
import '../application/overview_providers.dart';
import '../application/overview_tiles.dart';
import '../application/overview_today.dart';
import 'overview_session_parts.dart' show watchOverviewLine;

/// **Today**, at the top of the Board: what needs you — how long the oldest
/// has waited and what it asks — what finished since you last looked, what
/// is stuck, and what runs. Each part filters the Board and taps again to
/// clear; a part with nothing in it is left out.
///
/// [compact], where the row is narrow, draws one line for the caller to
/// slide sideways; otherwise the parts wrap as chips.
class OverviewTodayStrip extends ConsumerWidget {
  const OverviewTodayStrip({this.compact = false, super.key});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today = ref.watch(overviewTodayProvider);
    final filter = ref.watch(overviewPrefsProvider.select((p) => p.filter));
    final hidden = ref.watch(agentsHiddenWorkingCountProvider);
    final controller = ref.read(overviewPrefsProvider.notifier);
    final firstId = today.firstWaitingId;
    final firstCard = firstId == null
        ? null
        : overviewCardOf(ref.watch(overviewAllStatesBoardProvider), firstId);
    final question = firstCard == null
        ? null
        : watchOverviewLine(ref, firstCard);
    final shown = [
      for (final part in OverviewTodayPart.values)
        if (today.countOf(part) > 0 || part.selectedIn(filter)) part,
    ];
    if (shown.isEmpty && hidden == 0) {
      final theme = Theme.of(context);
      return Padding(
        key: const ValueKey('overview-all-clear'),
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.sm,
          vertical: Insets.xs,
        ),
        child: Text(
          'All clear',
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    void toggle(OverviewTodayPart part) {
      if (part.selectedIn(filter)) {
        controller.setStateFilter(null, null);
      } else {
        final own = part.filter;
        controller.setStateFilter(own.columns, own.states);
      }
    }

    final children = [
      for (final part in shown) ...[
        _TodayChip(
          part: part,
          today: today,
          question: part == OverviewTodayPart.needsYou ? question : null,
          selected: part.selectedIn(filter),
          onTap: () => toggle(part),
          onSeen: part == OverviewTodayPart.finished
              ? () => ref
                    .read(overviewLookedAtProvider.notifier)
                    .markLooked(ref.read(clockProvider).nowUtc())
              : null,
        ),
        if (part == OverviewTodayPart.running && hidden > 0)
          OverviewHiddenWorking(count: hidden),
      ],
      if (!shown.contains(OverviewTodayPart.running) && hidden > 0)
        OverviewHiddenWorking(count: hidden),
    ];
    if (compact) {
      return Row(
        key: const ValueKey('overview-today'),
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (i, child) in children.indexed) ...[
            if (i > 0) const SizedBox(width: Insets.xs),
            child,
          ],
        ],
      );
    }
    return Wrap(
      key: const ValueKey('overview-today'),
      spacing: Insets.xs,
      runSpacing: Insets.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    );
  }
}

/// One part of Today: its count and words, and Finished's "Seen".
class _TodayChip extends StatelessWidget {
  const _TodayChip({
    required this.part,
    required this.today,
    required this.selected,
    required this.onTap,
    this.question,
    this.onSeen,
  });

  final OverviewTodayPart part;
  final OverviewToday today;
  final bool selected;
  final VoidCallback onTap;
  final String? question;
  final VoidCallback? onSeen;

  /// The widest the first question is drawn, at 1x text.
  static const _questionWidth = Insets.xxl * 5;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final density = UiDensity.of(context);
    final count = today.countOf(part);
    final live = count > 0;
    final hue = switch (part) {
      OverviewTodayPart.needsYou => semantic.attention,
      OverviewTodayPart.finished => semantic.idle,
      OverviewTodayPart.stuck => semantic.failure,
      OverviewTodayPart.running => semantic.working,
    };
    final wait = today.oldestWait;
    final label = switch (part) {
      OverviewTodayPart.needsYou => 'needs you',
      OverviewTodayPart.finished => 'finished',
      OverviewTodayPart.stuck => 'stuck',
      OverviewTodayPart.running => null,
    };
    // Said in full to a screen reader and on hover; drawn short.
    final spoken = switch (part) {
      OverviewTodayPart.finished => 'finished since you looked',
      _ => label,
    };
    final caption = switch (part) {
      OverviewTodayPart.needsYou when wait != null && live =>
        'oldest ${compactAge(wait)}',
      _ => null,
    };
    final detail = switch (part) {
      OverviewTodayPart.stuck when live => today.stuckDetail,
      OverviewTodayPart.finished => 'Finished since you last looked',
      _ => null,
    };
    final question = this.question;
    final onSeen = this.onSeen;
    final radius = BorderRadius.circular(Radii.sm);
    final chip = Material(
      key: ValueKey('overview-today:${part.name}'),
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
                  part == OverviewTodayPart.running
                      ? today.runningLabel
                      : '$count',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: live ? hue : scheme.onSurfaceVariant,
                    fontWeight: live ? FontWeight.w700 : FontWeight.w400,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                if (label != null) ...[
                  const SizedBox(width: Insets.xs),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: live
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
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
                if (question != null && question.isNotEmpty) ...[
                  const SizedBox(width: Insets.xs),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.textScalerOf(
                        context,
                      ).scale(_questionWidth),
                    ),
                    child: Text(
                      '· $question',
                      key: const ValueKey('overview-today-question'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
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
    final said = [
      part == OverviewTodayPart.running ? today.runningLabel : '$count $spoken',
      ?caption,
      if (part == OverviewTodayPart.stuck) ?detail,
      ?question,
      selected
          ? 'showing only these; tap to show all'
          : 'tap to show only these',
    ].join(', ');
    final Widget tappable = Semantics(
      button: true,
      selected: selected,
      label: said,
      excludeSemantics: true,
      child: detail == null ? chip : Tooltip(message: detail, child: chip),
    );
    if (onSeen == null) return tappable;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: tappable),
        TextButton(
          key: const ValueKey('overview-today-seen'),
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
            minimumSize: Size(0, density.minRow),
          ),
          onPressed: onSeen,
          child: const Text('Seen'),
        ),
      ],
    );
  }
}

/// "3 hidden · Show": what Hide while working took off the tiles.
class OverviewHiddenWorking extends ConsumerWidget {
  const OverviewHiddenWorking({required this.count, super.key});

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
    // Running and waiting are Today's; only a pause is said here.
    final paused = ref.watch(
      capacityNowProvider.select((c) => c.limits.pauseBackground),
    );
    final facts = <Widget>[
      if (paused)
        Tooltip(
          message: kLaunchSlotRule,
          child: Text(
            'Background paused',
            key: const ValueKey('overview-capacity'),
            style: muted,
          ),
        ),
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
