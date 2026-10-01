import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:store_console/store_console.dart';

import '../../../core/util/clock_provider.dart';
import '../application/store_attention.dart';
import '../application/store_groups.dart';
import 'store_app_icon.dart';
import 'store_badges.dart';
import 'stores_format.dart';

/// An app read this much before the newest read is said to be older: its
/// store did not answer the last refresh.
const Duration _staleBehind = Duration(minutes: 5);

/// One app on the overview: its icon and name, a line per store with what is
/// live and how it is rated, and under each the things that want a look.
/// A coloured edge says the loudest of them at a glance.
class StoreGroupCard extends ConsumerWidget {
  const StoreGroupCard({
    required this.group,
    required this.onTap,
    this.selected = false,
    this.refreshedAt,
    super.key,
  });

  final StoreAppGroup group;
  final VoidCallback onTap;
  final bool selected;

  /// The newest read of the stores, so a card read before it can say so.
  final DateTime? refreshedAt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final edge = switch (group.signals.firstOrNull) {
      final ReleaseSignal signal => signalColor(context, signal),
      final StoreSignal signal when signal.tone == StoreTone.attention =>
        signalColor(context, signal),
      _ => null,
    };
    final readAt = group.readAt;
    final newest = refreshedAt;
    final stale =
        readAt != null &&
        newest != null &&
        newest.difference(readAt) > _staleBehind;
    final now = ref.watch(clockProvider).nowUtc();
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected
            ? SurfaceTones.of(context).selected
            : scheme.surfaceContainerLow,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          side: BorderSide(
            color: selected ? scheme.primary : scheme.outlineVariant,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          child: Stack(
            children: [
              if (edge != null)
                PositionedDirectional(
                  start: 0,
                  top: 0,
                  bottom: 0,
                  width: 3,
                  child: ColoredBox(color: edge),
                ),
              Padding(
                padding: const EdgeInsets.all(Insets.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _Heading(group: group),
                    const SizedBox(height: Insets.md),
                    for (final (i, entry) in group.entries.indexed) ...[
                      if (i > 0) const SizedBox(height: Insets.sm),
                      StoreEntryRow(entry: entry),
                    ],
                    if (stale) ...[
                      const SizedBox(height: Insets.sm),
                      Row(
                        children: [
                          Icon(
                            AppIcons.clockCounterClockwise,
                            size: Chrome.iconAction,
                            color: semantic.neutral,
                          ),
                          const SizedBox(width: Insets.xs),
                          Expanded(
                            child: Text(
                              'As read ${formatDataAge(now.difference(readAt))}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
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

class _Heading extends StatelessWidget {
  const _Heading({required this.group});

  final StoreAppGroup group;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      children: [
        StoreAppIconView(
          icon: group.icon,
          name: group.name,
          size: StoreAppIconView.listSize(context),
        ),
        const SizedBox(width: Insets.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                group.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  if (group.combinedManually) ...[
                    Tooltip(
                      message: 'Combined manually',
                      child: Icon(
                        AppIcons.linkSimple,
                        size: Chrome.iconAction,
                        color: scheme.onSurfaceVariant,
                        semanticLabel: 'Combined manually',
                      ),
                    ),
                    const SizedBox(width: Insets.xs),
                  ],
                  Expanded(
                    child: Text(
                      group.bundleIds.join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One store's line on a card: the store, what is live, its downloads and
/// rating; and under it what that store has to say.
class StoreEntryRow extends StatelessWidget {
  const StoreEntryRow({required this.entry, super.key});

  final StoreEntry entry;

  /// Wide enough for "App Store" at 1x text, so versions line up.
  static const double storeColumn = 72;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final snapshot = entry.snapshot;
    final rating = snapshot?.rating.valueOrNull;
    final downloads = snapshot?.downloads.valueOrNull;
    final scaler = MediaQuery.textScalerOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            SizedBox(
              width: scaler.scale(storeColumn),
              child: Text(
                storeShortLabel(entry.app.store),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(
              child: snapshot == null
                  ? Text('Not read yet', style: muted)
                  : _LiveVersion(snapshot: snapshot),
            ),
            if (downloads != null && downloads.days.length > 1) ...[
              const SizedBox(width: Insets.sm),
              _Downloads(series: downloads),
            ],
            if (rating != null) ...[
              const SizedBox(width: Insets.md),
              RatingFigure(rating: rating),
            ],
          ],
        ),
        if (entry.signals.isNotEmpty)
          Padding(
            padding: EdgeInsetsDirectional.only(
              start: scaler.scale(storeColumn),
              top: Insets.xs,
            ),
            child: Wrap(
              spacing: Insets.xs,
              runSpacing: Insets.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final signal in entry.signals) ...[
                  SignalPill(signal: signal),
                  if (signal case ReleaseSignal(
                    release: StoreRelease(rolloutFraction: final fraction?),
                  ))
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Insets.xs,
                        vertical: Insets.sm,
                      ),
                      child: RolloutBar(fraction: fraction, width: 40),
                    ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _LiveVersion extends StatelessWidget {
  const _LiveVersion({required this.snapshot});

  final StoreAppSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = theme.textTheme.bodySmall?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    if (snapshot.releases is ReadingMissing<List<StoreRelease>>) {
      return Text(
        'Releases unread',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style?.copyWith(color: scheme.onSurfaceVariant),
      );
    }
    final live = snapshot.live;
    if (live == null) {
      return Text(
        'Not live',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style?.copyWith(color: scheme.onSurfaceVariant),
      );
    }
    return Row(
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: SemanticColors.of(context).idle,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: Insets.xs),
        Flexible(
          child: Text(
            formatVersion(live),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style?.copyWith(fontWeight: FontWeight.w500),
            semanticsLabel: 'Live ${formatVersion(live)}',
          ),
        ),
      ],
    );
  }
}

class _Downloads extends StatelessWidget {
  const _Downloads({required this.series});

  final DownloadSeries series;

  /// Wide enough to show fourteen days as a shape, narrow enough for a card.
  static const sparklineWidth = 44.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message:
          '${formatCompactCount(series.total)} ${series.unit.toLowerCase()} '
          'over the last ${series.days.length} reported days',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Sparkline(
            values: [for (final day in series.days) day.count.toDouble()],
            color: theme.colorScheme.primary,
            width: sparklineWidth,
            semanticsLabel: '${series.unit} per day',
          ),
          const SizedBox(width: Insets.xs),
          Text(
            formatCompactCount(series.total),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// A card's shape while the stores are read for the first time, so the
/// overview fills in place rather than jumping.
class StoreCardSkeleton extends StatelessWidget {
  const StoreCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget bar(double width, double height) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
    );
    final icon = StoreAppIconView.listSize(context);
    return ExcludeSemantics(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(Insets.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  bar(icon, icon),
                  const SizedBox(width: Insets.md),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      bar(140, 12),
                      const SizedBox(height: Insets.xs),
                      bar(96, 10),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: Insets.md),
              bar(180, 10),
              const SizedBox(height: Insets.sm),
              bar(120, 10),
            ],
          ),
        ),
      ),
    );
  }
}
