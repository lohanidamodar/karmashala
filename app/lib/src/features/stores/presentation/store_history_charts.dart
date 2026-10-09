import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show StoreAppHistory, StoreDay;
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:store_console/store_console.dart';

import '../../../core/util/clock_provider.dart';
import '../application/store_groups.dart';
import '../application/store_history.dart';
import 'store_logo.dart';
import 'stores_format.dart';

/// How tall a history chart is on a phone, and wider.
const double kHistoryChartHeightNarrow = 120;
const double kHistoryChartHeight = 160;

/// Kept days further apart than this are not joined: the day between was
/// not read, and is drawn as a gap.
const Duration kHistoryChartBreak = Duration(hours: 36);

/// **Charts over time** for one app: its rating, reviews a week, crash and
/// ANR rates and installs, over 30, 90 or 365 days, release dates marked on
/// the time axis. A day nobody read is a gap, never a zero.
class StoreHistoryCharts extends ConsumerStatefulWidget {
  const StoreHistoryCharts({
    required this.group,
    required this.narrow,
    super.key,
  });

  final StoreAppGroup group;
  final bool narrow;

  @override
  ConsumerState<StoreHistoryCharts> createState() => _StoreHistoryChartsState();
}

class _StoreHistoryChartsState extends ConsumerState<StoreHistoryCharts> {
  StoreChartRange _range = StoreChartRange.month;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final apps = [for (final entry in widget.group.entries) entry.app];
    final async = ref.watch(storeHistoryProvider(storeHistoryKey(apps)));
    final now = ref.watch(clockProvider).nowUtc();
    final Widget body;
    if (async.value case final view?) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, app) in apps.indexed) ...[
            if (i > 0) const SizedBox(height: Insets.lg),
            if (apps.length > 1)
              Padding(
                padding: const EdgeInsets.only(bottom: Insets.sm),
                child: Row(
                  children: [
                    StoreLogo(app.store, size: Chrome.iconAction),
                    const SizedBox(width: Insets.xs),
                    Text(app.store.label, style: theme.textTheme.titleSmall),
                  ],
                ),
              ),
            _AppCharts(
              app: app,
              history: view.of(app.key),
              range: _range,
              now: now,
              height: widget.narrow
                  ? kHistoryChartHeightNarrow
                  : kHistoryChartHeight,
            ),
          ],
        ],
      );
    } else if (async.hasError) {
      body = Text(
        'The kept history could not be read from the Karmashala server.',
        style: muted,
      );
    } else {
      body = const Align(
        alignment: AlignmentDirectional.centerStart,
        child: InlineSpinner(semanticsLabel: 'Reading the kept history'),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: CompactSegmented<StoreChartRange>(
            key: const ValueKey('store-history-range'),
            segments: [
              for (final range in StoreChartRange.values)
                ButtonSegment(value: range, label: Text(range.label)),
            ],
            selected: _range,
            onChanged: (range) => setState(() => _range = range),
          ),
        ),
        const SizedBox(height: Insets.md),
        body,
      ],
    );
  }
}

class _AppCharts extends StatelessWidget {
  const _AppCharts({
    required this.app,
    required this.history,
    required this.range,
    required this.now,
    required this.height,
  });

  final StoreApp app;
  final StoreAppHistory? history;
  final StoreChartRange range;
  final DateTime now;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final held = history;
    if (held == null || held.days.isEmpty) {
      return Text(
        'No history yet. Karmashala keeps a row a day for each app as the '
        'stores are read.',
        key: const ValueKey('store-history-empty'),
        style: muted,
      );
    }
    final from = storeRangeStart(range, now);
    final end = now;
    final markers = [
      for (final release in storeReleaseDates(app.store, held.steps))
        if (!release.at.isBefore(from))
          ChartMarker(release.at, label: release.version),
    ];
    final days = held.days;

    List<TimeSeriesPoint> points(double? Function(StoreDay day) pick) => [
      for (final point in storeDaySeries(days, pick, from: from))
        TimeSeriesPoint(point.day, point.value),
    ];
    String day(DateTime at) => formatShortDay(at, now);

    final rating = points((day) => day.rating);
    final crash = points((day) => day.crashRate);
    final anr = points((day) => day.anrRate);
    final installs = points((day) => day.installs?.toDouble());
    final weeks = storeWeeklyReviews(days, from: from, to: end);
    final primary = theme.colorScheme.primary;

    Widget series({
      required String key,
      required String title,
      required List<TimeSeriesPoint> shown,
      required String Function(double value) valueLabel,
      required double minY,
      required double maxY,
      required Color color,
      String? note,
      String? absent,
      bool area = true,
    }) => _Chart(
      key: ValueKey('store-history-$key'),
      title: title,
      note: note,
      child: shown.isEmpty
          ? Text(absent ?? kNotRecorded, style: muted)
          : TimeSeriesChart(
              points: shown,
              start: from,
              end: end,
              minY: minY,
              maxY: maxY,
              color: color,
              markers: markers,
              breakAfter: kHistoryChartBreak,
              area: area,
              height: height,
              valueLabel: valueLabel,
              timeLabel: day,
              semanticsLabel:
                  '$title over the last ${range.days} days: '
                  '${shown.length} days recorded',
            ),
    );

    double top(List<TimeSeriesPoint> shown) => shown.isEmpty
        ? 1
        : shown.map((point) => point.value).reduce(math.max) * 1.2;
    final stability = app.store == StoreKind.appStore
        ? 'The App Store reports no crash or ANR rate.'
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        series(
          key: 'rating',
          title: 'Rating',
          shown: rating,
          valueLabel: (value) => '${value.toStringAsFixed(2)} ★',
          minY: 1,
          area: false,
          maxY: 5,
          color: primary,
        ),
        _Chart(
          key: const ValueKey('store-history-reviews'),
          title: 'Reviews a week',
          child: weeks.every((week) => week.count == null)
              ? Text(kNotRecorded, style: muted)
              : BarChart(
                  height: height,
                  color: primary,
                  semanticsLabel:
                      'Reviews a week over the last ${range.days} days',
                  bars: [
                    for (final week in weeks)
                      BarDatum(
                        label: day(week.week),
                        // Unknown is drawn as no bar, and said so.
                        value: week.count?.toDouble() ?? double.nan,
                        valueLabel: week.count == null
                            ? kNotRecorded
                            : '${week.count} '
                                  '${week.count == 1 ? 'review' : 'reviews'}',
                      ),
                  ],
                ),
        ),
        series(
          key: 'crash',
          title: 'Crash rate',
          shown: crash,
          valueLabel: formatRate,
          minY: 0,
          maxY: top(crash),
          color: SemanticColors.of(context).failure,
          absent: stability,
        ),
        series(
          key: 'anr',
          title: 'ANR rate',
          shown: anr,
          valueLabel: formatRate,
          minY: 0,
          maxY: top(anr),
          color: SemanticColors.of(context).attention,
          absent: stability,
        ),
        series(
          key: 'installs',
          title: 'Installs a day',
          note: 'Reported days late; the newest days are not in yet.',
          shown: installs,
          valueLabel: (value) => formatCompactCount(value.round()),
          minY: 0,
          maxY: top(installs),
          color: primary,
        ),
      ],
    );
  }
}

/// What a value nobody recorded says.
const String kNotRecorded = 'Not recorded';

class _Chart extends StatelessWidget {
  const _Chart({
    required this.title,
    required this.child,
    this.note,
    super.key,
  });

  final String title;
  final String? note;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: theme.textTheme.labelLarge),
          if (note case final note?) Text(note, style: muted),
          const SizedBox(height: Insets.xs),
          child,
        ],
      ),
    );
  }
}
