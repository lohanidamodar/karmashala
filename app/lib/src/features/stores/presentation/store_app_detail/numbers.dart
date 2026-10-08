// The headline numbers, what a store could not give, and the downloads chart.

part of '../store_app_detail.dart';

/// The headline numbers of every store; a reading the store did not give is
/// a line under them saying why, never a zero (PROJECT.md §19).
class _Numbers extends ConsumerWidget {
  const _Numbers({required this.group, required this.maxColumns});

  final StoreAppGroup group;
  final int maxColumns;

  static const _unavailable = 'unavailable';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider).nowUtc();
    final both = group.entries.length > 1;
    final tiles = <Widget>[];
    // Grouped under their store, so they read as one block per store.
    final notes = <StoreKind, List<Widget>>{};
    for (final entry in group.entries) {
      final snapshot = entry.snapshot;
      if (snapshot == null) continue;
      final store = entry.app.store;
      // Which store a tile is from, when there are two: its logo before the
      // label, its name for a screen reader (owner, 2026-10-01).
      final logo = both ? StoreLogo(store, size: Chrome.iconSmall) : null;
      String spoken(String what) => both ? '$what · ${store.label}' : what;
      void note(String what, ReadingMissing<Object?> missing) => notes
          .putIfAbsent(store, () => [])
          .add(MissingReadingLine(what: what, reading: missing));

      switch (snapshot.rating) {
        case ReadingValue(:final value):
          final trend = value.trend;
          final caption = [
            if (value.count case final count?)
              '${formatCompactCount(count)} ratings',
            if (trend != null)
              '${formatRatingChange(trend.change)} since '
                  '${formatShortDay(trend.since, now)}',
          ];
          tiles.add(
            StatTile(
              label: 'Rating',
              leading: logo,
              semanticLabel: spoken('Rating'),
              value: '${value.average.toStringAsFixed(1)} ★',
              caption: caption.isEmpty ? null : caption.join(' · '),
            ),
          );
        case final ReadingMissing<RatingSummary> missing:
          if (!missing.expected) {
            tiles.add(
              StatTile(
                label: 'Rating',
                leading: logo,
                semanticLabel: spoken('Rating'),
                value: null,
                unrecorded: _unavailable,
              ),
            );
          }
          note('Rating', missing);
      }

      switch (snapshot.vitals) {
        case ReadingValue(:final value):
          final window = '${value.to.difference(value.from).inDays} days';
          tiles
            ..add(
              StatTile(
                label: 'Crash rate',
                leading: logo,
                semanticLabel: spoken('Crash rate'),
                value: switch (value.crashRate) {
                  final rate? => formatRate(rate),
                  null => null,
                },
                unrecorded: 'too little data',
                caption: window,
                tooltip: 'The share of daily users who saw a crash.',
              ),
            )
            ..add(
              StatTile(
                label: 'ANR rate',
                leading: logo,
                semanticLabel: spoken('ANR rate'),
                value: switch (value.anrRate) {
                  final rate? => formatRate(rate),
                  null => null,
                },
                unrecorded: 'too little data',
                caption: window,
                tooltip:
                    'The share of daily users who saw the app stop '
                    'responding.',
              ),
            );
        case final ReadingMissing<VitalsSummary> missing:
          if (!missing.expected) {
            tiles.add(
              StatTile(
                label: 'Crash and ANR',
                leading: logo,
                semanticLabel: spoken('Crash and ANR'),
                value: null,
                unrecorded: _unavailable,
              ),
            );
          }
          note('Crash and ANR rates', missing);
      }

      switch (snapshot.downloads) {
        case ReadingValue(:final value):
          tiles.add(
            StatTile(
              label: '${value.unit} 14 d',
              leading: logo,
              semanticLabel: spoken('${value.unit} 14 d'),
              value: value.days.isEmpty
                  ? null
                  : formatCompactCount(value.total),
              unrecorded: 'none reported yet',
              caption: value.days.isEmpty
                  ? null
                  : 'to ${formatReportDay(value.days.last.day)}',
              tooltip: 'Stores report downloads a day or more late.',
            ),
          );
        case final ReadingMissing<DownloadSeries> missing:
          if (!missing.expected) {
            tiles.add(
              StatTile(
                label: 'Downloads',
                leading: logo,
                semanticLabel: spoken('Downloads'),
                value: null,
                unrecorded: _unavailable,
              ),
            );
          }
          note('Downloads', missing);
      }

      final allTimeLabel = store == StoreKind.appStore
          ? 'All-time downloads'
          : 'All-time installs';
      switch (snapshot.allTimeInstalls) {
        case null:
          break;
        case ReadingValue(:final value, :final checkedAt):
          tiles.add(
            StatTile(
              label: allTimeLabel,
              leading: logo,
              semanticLabel: spoken(allTimeLabel),
              value: formatInstallFigure(value),
              caption: describeInstallMeasure(value),
              tooltip: describeInstallTotal(value, store, readAt: checkedAt),
            ),
          );
        case final ReadingMissing<InstallTotal> missing:
          if (!missing.expected) {
            tiles.add(
              StatTile(
                label: allTimeLabel,
                leading: logo,
                semanticLabel: spoken(allTimeLabel),
                value: null,
                unrecorded: _unavailable,
              ),
            );
          }
          note(allTimeLabel, missing);
      }
    }
    return _Stack(
      children: [
        if (tiles.isNotEmpty)
          StatTileGrid(tiles: tiles, maxColumns: maxColumns),
        if (notes.isNotEmpty) _MissingNotes(notes: notes),
      ],
    );
  }
}

/// What a store could not give, a block per store under its logo and name.
class _MissingNotes extends StatelessWidget {
  const _MissingNotes({required this.notes});

  final Map<StoreKind, List<Widget>> notes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, MapEntry(key: store, value: lines))
              in notes.entries.indexed) ...[
            if (i > 0) const SizedBox(height: Insets.md),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: StoreLogo.named(
                store,
                size: Chrome.iconAction,
                color: scheme.onSurface,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            for (final line in lines)
              Padding(
                padding: const EdgeInsets.only(top: Insets.xs),
                child: line,
              ),
          ],
        ],
      ),
    );
  }
}

class _DownloadsChart extends StatelessWidget {
  const _DownloadsChart({
    required this.store,
    required this.series,
    required this.height,
  });

  /// Named when the app is on both stores.
  final StoreKind? store;
  final DownloadSeries series;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final days = series.days;
    final peak = days.fold(0, (most, day) => math.max(most, day.count));
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final store = this.store;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: Insets.sm,
            runSpacing: Insets.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (store != null)
                StoreLogo.named(
                  store,
                  size: Chrome.iconAction,
                  color: scheme.onSurface,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              Text(
                '${formatCompactCount(series.total)} '
                '${series.unit.toLowerCase()} over ${days.length} reported '
                'days',
                style: muted,
              ),
            ],
          ),
          const SizedBox(height: Insets.sm),
          TimeSeriesChart(
            points: [
              for (final day in days)
                TimeSeriesPoint(day.day, day.count.toDouble()),
            ],
            start: days.first.day,
            end: days.last.day,
            // Headroom over the tallest day; one, so a flat zero has a scale.
            maxY: math.max(1.0, peak * 1.1),
            color: scheme.primary,
            height: height,
            semanticsLabel: [
              ?store?.label,
              '${series.unit} per day',
            ].join(' · '),
            valueLabel: (value) => formatCompactCount(value.round()),
            timeLabel: formatReportDay,
          ),
        ],
      ),
    );
  }
}
