import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:store_console/store_console.dart';

import '../../../core/util/clock_provider.dart';
import '../../git/application/remote_links.dart' show openExternalUrlProvider;
import '../application/store_attention.dart';
import '../application/store_groups.dart';
import 'store_app_icon.dart';
import 'store_logo.dart';
import 'store_badges.dart';
import 'store_combine.dart';
import 'store_detail_errors.dart';
import 'store_detail_releases.dart';
import 'store_detail_reviews.dart';
import 'store_installs.dart';
import 'stores_format.dart';

/// Everything read about one app: what wants a look, its releases per store
/// and track, its numbers, its downloads and its reviews.
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
    final read = group.entries.any((entry) => entry.snapshot != null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(group: group, pushed: pushed, onClose: onClose),
        const Divider(height: 1),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              Insets.lg,
              Insets.md,
              Insets.lg,
              Insets.xl,
            ),
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: Chrome.readableWidth,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Links(group: group),
                    if (group.combined != StoreCombined.byId) ...[
                      const SizedBox(height: Insets.xs),
                      StoreCombineBar(group: group),
                    ],
                    if (group.signals.isNotEmpty) ...[
                      const SizedBox(height: Insets.md),
                      _SignalsPanel(group: group),
                    ],
                    const _Section('Releases'),
                    for (final (i, entry) in group.entries.indexed) ...[
                      if (i > 0) const SizedBox(height: Insets.sm),
                      StoreReleasesCard(
                        key: ValueKey('releases-${entry.app.key}'),
                        entry: entry,
                      ),
                    ],
                    if (read) ...[
                      const _Section('Ratings and stability'),
                      _Numbers(group: group),
                      if (_downloadCharts(group) case final charts
                          when charts.isNotEmpty) ...[
                        const _Section('Downloads'),
                        ...charts,
                      ],
                      if (hasErrorIssues(group)) ...[
                        const _Section('Crashes and ANRs'),
                        StoreErrorIssuesSection(group: group),
                      ],
                    ],
                    const _Section('Reviews'),
                    StoreReviewsSection(group: group),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  static List<Widget> _downloadCharts(StoreAppGroup group) => [
    for (final entry in group.entries)
      if (entry.snapshot?.downloads.valueOrNull case final series?
          when series.days.length > 1)
        _DownloadsChart(
          store: group.entries.length > 1 ? entry.app.store : null,
          series: series,
        ),
  ];
}

class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: Insets.xl, bottom: Insets.sm),
    child: Semantics(header: true, child: EyebrowLabel(title)),
  );
}

class _Header extends StatelessWidget {
  const _Header({
    required this.group,
    required this.pushed,
    required this.onClose,
  });

  final StoreAppGroup group;
  final bool pushed;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.sm,
        Insets.sm,
        Insets.sm,
        Insets.md,
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
          StoreAppIconView(
            icon: group.icon,
            name: group.name,
            size: StoreAppIconView.detailSize(context),
          ),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  group.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                // Combined by hand, each store's id on its own line.
                for (final id in storeGroupIdLines(group))
                  SelectableText(
                    id,
                    maxLines: 1,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                if (group.combinedManually) ...[
                  const SizedBox(height: Insets.xs),
                  const CombinedManuallyChip(),
                ],
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
    );
  }
}

/// Each store's console and listing, one click away.
class _Links extends ConsumerWidget {
  const _Links({required this.group});

  final StoreAppGroup group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.read(openExternalUrlProvider);
    return Wrap(
      spacing: Insets.xs,
      runSpacing: Insets.xs,
      children: [
        for (final entry in group.entries)
          for (final link in storeLinks(entry.app))
            OutlinedButton.icon(
              onPressed: () => open(link.url),
              icon: const Icon(
                AppIcons.arrowSquareOut,
                size: Chrome.iconAction,
              ),
              label: Text(link.label),
            ),
      ],
    );
  }
}

/// What wants a look, as sentences, loudest first.
class _SignalsPanel extends StatelessWidget {
  const _SignalsPanel({required this.group});

  final StoreAppGroup group;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final signals = group.signals;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.md,
          vertical: Insets.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final signal in signals)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Insets.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Icon(
                        signalIcon(signal),
                        size: Chrome.icon,
                        color: signalColor(context, signal),
                      ),
                    ),
                    const SizedBox(width: Insets.sm),
                    Expanded(
                      child: Text(
                        signalSentence(signal),
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    if (signal case ReleaseSignal(
                      release: StoreRelease(rolloutFraction: final fraction?),
                    )) ...[
                      const SizedBox(width: Insets.sm),
                      Padding(
                        padding: const EdgeInsets.only(top: Insets.sm),
                        child: RolloutBar(fraction: fraction),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The headline numbers of every store; a reading the store did not give is
/// a line under them saying why, never a zero (PROJECT.md §19).
class _Numbers extends ConsumerWidget {
  const _Numbers({required this.group});

  final StoreAppGroup group;

  static const _unavailable = 'unavailable';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider).nowUtc();
    final both = group.entries.length > 1;
    final tiles = <Widget>[];
    final notes = <Widget>[];
    for (final entry in group.entries) {
      final snapshot = entry.snapshot;
      if (snapshot == null) continue;
      final store = entry.app.store;
      // Which store a tile is from, when there are two: its logo before the
      // label, its name for a screen reader (owner, 2026-10-01).
      final logo = both ? StoreLogo(store, size: 13) : null;
      String spoken(String what) => both ? '$what · ${store.label}' : what;

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
          notes.add(
            MissingReadingLine(what: '${store.label} rating', reading: missing),
          );
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
          notes.add(
            MissingReadingLine(
              what: '${store.label} crash and ANR rates',
              reading: missing,
            ),
          );
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
          notes.add(
            MissingReadingLine(
              what: '${store.label} downloads',
              reading: missing,
            ),
          );
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
          notes.add(
            MissingReadingLine(
              what:
                  '${store.label} all-time '
                  '${store == StoreKind.appStore ? 'downloads' : 'installs'}',
              reading: missing,
            ),
          );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (tiles.isNotEmpty) StatTileGrid(tiles: tiles),
        for (final (i, note) in notes.indexed) ...[
          SizedBox(height: i == 0 && tiles.isEmpty ? 0 : Insets.sm),
          note,
        ],
      ],
    );
  }
}

class _DownloadsChart extends StatelessWidget {
  const _DownloadsChart({required this.store, required this.series});

  /// Named when the app is on both stores.
  final StoreKind? store;
  final DownloadSeries series;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final days = series.days;
    final peak = days.fold(0, (most, day) => math.max(most, day.count));
    final title = [
      ?store?.label,
      '${formatCompactCount(series.total)} ${series.unit.toLowerCase()} over '
          '${days.length} reported days',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Insets.xs),
          TimeSeriesChart(
            points: [
              for (final day in days)
                TimeSeriesPoint(day.day, day.count.toDouble()),
            ],
            start: days.first.day,
            end: days.last.day,
            // Headroom over the tallest day; one, so a flat zero has a scale.
            maxY: math.max(1.0, peak * 1.1),
            color: theme.colorScheme.primary,
            semanticsLabel: '${series.unit} per day',
            valueLabel: (value) => formatCompactCount(value.round()),
            timeLabel: formatReportDay,
          ),
        ],
      ),
    );
  }
}
