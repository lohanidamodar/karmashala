import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/rows.dart' show compactAge;
import 'package:karmashala_ui/tokens.dart';
import 'package:store_console/store_console.dart';

import '../../../core/util/clock_provider.dart';
import '../application/store_groups.dart';
import '../application/store_history.dart';
import '../application/store_timeline.dart';
import 'store_badges.dart';
import 'store_logo.dart';
import 'stores_format.dart';

/// How many releases a store's timeline shows before "Show more".
const int kTimelineReleasesShown = 3;

/// The narrowest a step is drawn across: below this many per step the
/// timeline runs down the page instead.
const double kTimelineStepMinWidth = 132;

/// **Each release's path** on the public track, per store: submitted,
/// waiting for review, in review, approved, live — Play's rollout steps on
/// the way — or rejected with what the store said, each step with when and
/// how long it took; and how long review usually takes. Across on a wide
/// detail, down on a phone.
class StoreReleaseTimelines extends ConsumerStatefulWidget {
  const StoreReleaseTimelines({required this.group, super.key});

  final StoreAppGroup group;

  @override
  ConsumerState<StoreReleaseTimelines> createState() =>
      _StoreReleaseTimelinesState();
}

class _StoreReleaseTimelinesState extends ConsumerState<StoreReleaseTimelines> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final apps = [for (final entry in widget.group.entries) entry.app];
    final async = ref.watch(storeHistoryProvider(storeHistoryKey(apps)));
    final now = ref.watch(clockProvider).nowUtc();
    final view = async.value;
    if (view == null) {
      if (async.hasError) {
        return Text(
          'The release steps could not be read from the Karmashala server.',
          style: muted,
        );
      }
      return const Align(
        alignment: AlignmentDirectional.centerStart,
        child: InlineSpinner(semanticsLabel: 'Reading the release steps'),
      );
    }
    final perStore = [
      for (final app in apps)
        (
          app: app,
          timelines: releaseTimelines(
            app.store,
            view.of(app.key)?.steps ?? const [],
            now: now,
          ),
        ),
    ];
    if (perStore.every((store) => store.timelines.isEmpty)) {
      return Text(
        'No release steps yet. Karmashala records each step as the stores '
        'are read, so a release submitted from now on shows its whole path.',
        key: const ValueKey('store-timeline-empty'),
        style: muted,
      );
    }
    final hidden = perStore.any(
      (store) => store.timelines.length > kTimelineReleasesShown,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, store) in perStore.indexed)
          if (store.timelines.isNotEmpty) ...[
            if (i > 0) const SizedBox(height: Insets.lg),
            _StoreTimelines(
              store: store.app.store,
              timelines: _all
                  ? store.timelines
                  : store.timelines.take(kTimelineReleasesShown).toList(),
              usual: usualReviewTime(store.timelines),
            ),
          ],
        if (hidden)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: () => setState(() => _all = !_all),
              child: Text(_all ? 'Show fewer' : 'Show every release'),
            ),
          ),
      ],
    );
  }
}

/// `Apple review: usually 1d 4h`.
String usualReviewSentence(
  StoreKind store,
  ({Duration usual, int over}) usual,
) {
  final who = store == StoreKind.appStore ? 'Apple' : 'Google Play';
  final releases = usual.over == 1 ? 'release' : 'releases';
  return '$who review: usually ${compactAge(usual.usual)} '
      '(last ${usual.over} $releases)';
}

class _StoreTimelines extends StatelessWidget {
  const _StoreTimelines({
    required this.store,
    required this.timelines,
    required this.usual,
  });

  final StoreKind store;
  final List<ReleaseTimeline> timelines;
  final ({Duration usual, int over})? usual;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final usual = this.usual;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            StoreLogo(store, size: Chrome.iconAction),
            const SizedBox(width: Insets.xs),
            Expanded(
              child: Text(
                usual == null
                    ? '${store.label}: no review seen from start to verdict yet'
                    : usualReviewSentence(store, usual),
                key: ValueKey('store-review-time:${store.name}'),
                style: muted,
              ),
            ),
          ],
        ),
        for (final timeline in timelines) ...[
          const SizedBox(height: Insets.sm),
          _TimelineCard(timeline: timeline),
        ],
      ],
    );
  }
}

class _TimelineCard extends StatelessWidget {
  const _TimelineCard({required this.timeline});

  final ReleaseTimeline timeline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final reason = timeline.rejectionReason;
    return DecoratedBox(
      key: ValueKey('store-timeline:${timeline.track}:${timeline.name}'),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Insets.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: Insets.sm,
              runSpacing: Insets.xxs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  timeline.name,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                StatusPill(
                  label: timeline.latest.words,
                  color: releaseStateColor(context, timeline.latest.state),
                ),
              ],
            ),
            if (reason != null) ...[
              const SizedBox(height: Insets.xs),
              Text(
                'The store says: $reason',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: SemanticColors.of(context).failure,
                ),
              ),
            ],
            const SizedBox(height: Insets.sm),
            LayoutBuilder(
              builder: (context, constraints) {
                final scaler = MediaQuery.textScalerOf(context);
                final width = constraints.maxWidth;
                // Down a phone; across where it is wide enough for every step.
                final across =
                    !WidthClass.of(width, textScaler: scaler).isCompact &&
                    width >=
                        timeline.steps.length *
                            scaler.scale(kTimelineStepMinWidth);
                return across
                    ? _Across(steps: timeline.steps)
                    : _Down(steps: timeline.steps);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// How long a step took: `1d 4h`, `≥ 2h` when it was first read already
/// there, `1d 4h so far` for where it is now.
String stepSpent(ReleaseTimelineStep step) {
  final spent = step.spent;
  if (spent == null) return '';
  final age = compactAge(spent);
  final floor = step.atLeast ? '≥ $age' : age;
  return step.current ? '$floor so far' : floor;
}

String _when(ReleaseTimelineStep step, DateTime now) {
  final at =
      '${formatShortDay(step.at, now)} ${formatClock(step.at.toLocal())}';
  return step.atLeast ? 'First read $at' : at;
}

class _Dot extends StatelessWidget {
  const _Dot({required this.step});

  final ReleaseTimelineStep step;

  @override
  Widget build(BuildContext context) {
    final color = releaseStateColor(context, step.state);
    return Icon(
      step.current ? AppIcons.circleFill : AppIcons.circle,
      size: Chrome.iconAction,
      color: color,
    );
  }
}

class _StepText extends ConsumerWidget {
  const _StepText({required this.step, required this.across});

  final ReleaseTimelineStep step;
  final bool across;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final now = ref.watch(clockProvider).nowUtc();
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final spent = stepSpent(step);
    return Column(
      crossAxisAlignment: across
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.stretch,
      children: [
        Text(
          step.words,
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: step.current ? FontWeight.w600 : null,
          ),
        ),
        Text(_when(step, now), style: muted),
        if (spent.isNotEmpty) Text(spent, style: muted),
      ],
    );
  }
}

/// The steps left to right, a rule between their dots.
class _Across extends StatelessWidget {
  const _Across({required this.steps});

  final List<ReleaseTimelineStep> steps;

  @override
  Widget build(BuildContext context) {
    final rule = Theme.of(context).colorScheme.outlineVariant;
    return Row(
      key: const ValueKey('store-timeline-across'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, step) in steps.indexed)
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _Dot(step: step),
                    if (i < steps.length - 1)
                      Expanded(child: Divider(color: rule, height: 1)),
                  ],
                ),
                const SizedBox(height: Insets.xs),
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: Insets.sm),
                  child: _StepText(step: step, across: true),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The steps top to bottom, a rule down the side.
class _Down extends StatelessWidget {
  const _Down({required this.steps});

  final List<ReleaseTimelineStep> steps;

  @override
  Widget build(BuildContext context) {
    final rule = Theme.of(context).colorScheme.outlineVariant;
    return Column(
      key: const ValueKey('store-timeline-down'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, step) in steps.indexed)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Column(
                  children: [
                    _Dot(step: step),
                    if (i < steps.length - 1)
                      Expanded(child: VerticalDivider(color: rule, width: 1)),
                  ],
                ),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Padding(
                    padding: i < steps.length - 1
                        ? const EdgeInsets.only(bottom: Insets.sm)
                        : EdgeInsets.zero,
                    child: _StepText(step: step, across: false),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
