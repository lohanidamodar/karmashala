import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:store_console/store_console.dart';

import '../../git/application/remote_links.dart' show openExternalUrlProvider;
import '../application/stores_dashboard.dart';
import 'store_app_card.dart';
import 'stores_format.dart';

/// Everything read about one app: per store, its releases, its numbers, its
/// downloads over time and its reviews.
class StoreGroupDetail extends StatelessWidget {
  const StoreGroupDetail({
    required this.group,
    required this.onClose,
    required this.pushed,
    super.key,
  });

  final StoreAppGroup group;
  final VoidCallback onClose;

  /// Whether this stands in the dashboard's place (compact) rather than
  /// beside it: the way out is then a back arrow, not a close.
  final bool pushed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.sm,
            vertical: Insets.xs,
          ),
          child: Row(
            children: [
              if (pushed)
                IconButton(
                  tooltip: 'Back to all apps',
                  icon: const Icon(AppIcons.arrowLeft),
                  onPressed: onClose,
                )
              else
                const SizedBox(width: Insets.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      group.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                    Text(
                      group.bundleId,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (!pushed)
                IconButton(
                  tooltip: 'Close details',
                  icon: const Icon(AppIcons.x),
                  onPressed: onClose,
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Insets.lg),
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: Chrome.readableWidth,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final entry in group.entries)
                      _EntryDetail(entry: entry),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _EntryDetail extends ConsumerWidget {
  const _EntryDetail({required this.entry});

  final StoreEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final app = entry.app;
    final snapshot = entry.snapshot;
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: Insets.sm,
            children: [
              Semantics(
                header: true,
                child: Text(app.store.label, style: theme.textTheme.titleSmall),
              ),
              TextButton.icon(
                onPressed: () =>
                    ref.read(openExternalUrlProvider)(storePageUrl(app)),
                icon: const Icon(
                  AppIcons.arrowSquareOut,
                  size: Chrome.iconAction,
                ),
                label: Text(storePageLabel(app.store)),
              ),
            ],
          ),
          const SizedBox(height: Insets.sm),
          if (snapshot == null)
            Text('Not read yet. Refresh to read it.', style: muted)
          else ...[
            const EyebrowLabel('Releases'),
            const SizedBox(height: Insets.xs),
            _Releases(reading: snapshot.releases),
            const SizedBox(height: Insets.lg),
            StatTileGrid(tiles: _tiles(snapshot)),
            for (final line in _missingNumbers(snapshot)) ...[
              const SizedBox(height: Insets.xs),
              line,
            ],
            const SizedBox(height: Insets.lg),
            const EyebrowLabel('Downloads'),
            const SizedBox(height: Insets.xs),
            _DownloadsChart(reading: snapshot.downloads),
            const SizedBox(height: Insets.lg),
            const EyebrowLabel('Reviews'),
            const SizedBox(height: Insets.xs),
            _Reviews(store: app.store, reading: snapshot.reviews),
          ],
        ],
      ),
    );
  }

  static const _unavailable = 'not available';

  List<Widget> _tiles(StoreAppSnapshot snapshot) {
    final rating = snapshot.rating.valueOrNull;
    final reviews = snapshot.reviews.valueOrNull;
    final vitals = snapshot.vitals.valueOrNull;
    final downloads = snapshot.downloads.valueOrNull;
    final ratings = rating?.count;
    final window = vitals == null
        ? null
        : '${vitals.to.difference(vitals.from).inDays} days';
    // Too little data is the store's answer, not a missing one.
    final rateUnrecorded = vitals == null ? _unavailable : 'too little data';
    return [
      StatTile(
        label: 'Rating',
        value: rating == null ? null : '${rating.average.toStringAsFixed(1)} ★',
        unrecorded: _unavailable,
        caption: ratings == null
            ? null
            : '${formatCompactCount(ratings)} ratings',
      ),
      StatTile(
        label: 'Reviews',
        value: reviews == null ? null : '${reviews.length}',
        unrecorded: _unavailable,
        caption: reviews == null
            ? null
            : snapshot.app.store == StoreKind.googlePlay
            ? 'last 7 days'
            : 'most recent',
      ),
      StatTile(
        label: 'Crash rate',
        value: switch (vitals?.crashRate) {
          final rate? => formatRate(rate),
          null => null,
        },
        unrecorded: rateUnrecorded,
        caption: window,
        tooltip: 'The share of daily users who saw a crash.',
      ),
      StatTile(
        label: 'ANR rate',
        value: switch (vitals?.anrRate) {
          final rate? => formatRate(rate),
          null => null,
        },
        unrecorded: rateUnrecorded,
        caption: window,
        tooltip: 'The share of daily users who saw the app stop responding.',
      ),
      StatTile(
        label: 'Downloads 14 d',
        value: downloads == null || downloads.days.isEmpty
            ? null
            : formatCompactCount(downloads.total),
        unrecorded: downloads == null ? _unavailable : 'none reported yet',
        caption: downloads?.unit,
      ),
    ];
  }

  /// Why a tile above has no figure, one line each.
  List<Widget> _missingNumbers(StoreAppSnapshot snapshot) => [
    if (snapshot.rating case final ReadingMissing<RatingSummary> missing)
      MissingReadingLine(what: 'Rating', reading: missing),
    if (snapshot.vitals case final ReadingMissing<VitalsSummary> missing)
      MissingReadingLine(what: 'Crash and ANR rate', reading: missing),
  ];
}

class _Releases extends StatelessWidget {
  const _Releases({required this.reading});

  final Reading<List<StoreRelease>> reading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final reading = this.reading;
    if (reading is ReadingMissing<List<StoreRelease>>) {
      return MissingReadingLine(what: 'Releases', reading: reading);
    }
    final releases = reading.valueOrNull ?? const <StoreRelease>[];
    if (releases.isEmpty) return Text('No releases.', style: muted);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final release in releases)
          Padding(
            padding: const EdgeInsets.only(bottom: Insets.xs),
            child: Wrap(
              spacing: Insets.md,
              runSpacing: Insets.hair,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  release.track,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  formatVersion(release),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                ReleaseStateLabel(release: release),
                if (release.date case final date?)
                  Text(formatDay(date), style: muted),
              ],
            ),
          ),
      ],
    );
  }
}

class _DownloadsChart extends StatelessWidget {
  const _DownloadsChart({required this.reading});

  final Reading<DownloadSeries> reading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final reading = this.reading;
    if (reading is ReadingMissing<DownloadSeries>) {
      return MissingReadingLine(what: 'Downloads', reading: reading);
    }
    final series = reading.valueOrNull;
    final days = series?.days ?? const <DailyCount>[];
    if (series == null || days.isEmpty) {
      return Text('The store has reported no days yet.', style: muted);
    }
    // One day is a number, not a line.
    if (days.length < 2) {
      return Text(
        '${formatCompactCount(series.total)} ${series.unit.toLowerCase()} on '
        '${formatDay(days.single.day)}.',
        style: muted,
      );
    }
    final peak = days.fold(0, (most, day) => math.max(most, day.count));
    return TimeSeriesChart(
      points: [
        for (final day in days) TimeSeriesPoint(day.day, day.count.toDouble()),
      ],
      start: days.first.day,
      end: days.last.day,
      // Headroom over the tallest day; one, so a flat zero still has a scale.
      maxY: math.max(1.0, peak * 1.1),
      color: theme.colorScheme.primary,
      semanticsLabel: '${series.unit} per day',
      valueLabel: (value) => formatCompactCount(value.round()),
      timeLabel: formatDay,
    );
  }
}

class _Reviews extends StatelessWidget {
  const _Reviews({required this.store, required this.reading});

  final StoreKind store;
  final Reading<List<StoreReview>> reading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final reading = this.reading;
    final reviews = reading.valueOrNull ?? const <StoreReview>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (store == StoreKind.googlePlay)
          Padding(
            padding: const EdgeInsets.only(bottom: Insets.sm),
            child: Text(
              'Google Play’s API only returns the last 7 days of reviews.',
              style: muted,
            ),
          ),
        if (reading is ReadingMissing<List<StoreReview>>)
          MissingReadingLine(what: 'Reviews', reading: reading)
        else if (reviews.isEmpty)
          Text('No reviews.', style: muted),
        for (final review in reviews) _Review(review: review),
      ],
    );
  }
}

class _Review extends StatelessWidget {
  const _Review({required this.review});

  final StoreReview review;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final meta = [
      ?review.author,
      ?review.locale,
      if (review.appVersion case final version?) 'v$version',
      formatDay(review.createdAt),
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                label: '${review.rating} of 5 stars',
                child: ExcludeSemantics(
                  child: Text(
                    formatStars(review.rating),
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ),
              if (review.title case final title? when title.isNotEmpty) ...[
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (review.body.isNotEmpty)
            Text(review.body, style: theme.textTheme.bodyMedium),
          Text(meta, style: muted),
          if (review.reply case final reply?)
            Padding(
              padding: const EdgeInsets.only(left: Insets.lg, top: Insets.xs),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  EyebrowLabel(
                    review.repliedAt == null
                        ? 'Developer reply'
                        : 'Developer reply · ${formatDay(review.repliedAt!)}',
                  ),
                  Text(reply, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
