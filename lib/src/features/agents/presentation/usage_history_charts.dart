import 'dart:math' as math;

import 'package:agent_cli/usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/usage_history.dart';
import 'usage_chip.dart' show formatResetClock;

/// The longest history any usage surface reads at once.
const Duration kUsageHistoryWindow = Duration(days: 7);

/// A history query for [account] ending at [now], rounded to the minute so a
/// ticking clock reuses one provider.
({String account, DateTime from}) usageHistoryQuery(
  String account,
  DateTime now,
) {
  final utc = now.toUtc();
  final minute = DateTime.utc(
    utc.year,
    utc.month,
    utc.day,
    utc.hour,
    utc.minute,
  );
  return (account: account, from: minute.subtract(kUsageHistoryWindow));
}

/// How far back a window's chart looks: a day for a short window, the window
/// itself for a long one, never more than the history that is read.
Duration usageChartRange(Duration? span) {
  if (span == null || span <= const Duration(days: 1)) {
    return const Duration(hours: 24);
  }
  return span > kUsageHistoryWindow ? kUsageHistoryWindow : span;
}

/// The samples of one window since [from], oldest first.
List<UsageSample> samplesOf(
  List<UsageSample> history,
  String windowLabel, {
  DateTime? from,
}) => [
  for (final sample in history)
    if (sample.windowLabel == windowLabel &&
        (from == null || !sample.recordedAt.isBefore(from)))
      sample,
];

/// A plain-words summary of a series, for a screen reader.
String usageSeriesSummary(
  String label,
  List<UsageSample> samples,
  Duration range,
) {
  final hours = range.inHours;
  final over = hours >= 48 ? '${range.inDays} days' : '$hours hours';
  if (samples.isEmpty) return '$label over the last $over: no readings';
  final peak = samples.map((s) => s.percent).reduce(math.max);
  final resets = _resetsWithin(samples).length;
  return '$label over the last $over: from ${samples.first.percent.round()}% '
      'to ${samples.last.percent.round()}%, peak ${peak.round()}%'
      '${resets == 0 ? '' : ', $resets ${resets == 1 ? 'reset' : 'resets'}'}';
}

/// Moments a window reset between two samples: the earlier sample's reset
/// time, whenever the next sample names a later one.
List<DateTime> _resetsWithin(List<UsageSample> samples) {
  final resets = <DateTime>[];
  for (var i = 1; i < samples.length; i++) {
    final before = samples[i - 1].resetsAt;
    final after = samples[i].resetsAt;
    if (before == null || after == null) continue;
    if (after.difference(before) > const Duration(minutes: 2)) {
      resets.add(before);
    }
  }
  return resets;
}

/// An account's recorded history: a window picker, the chosen window over time
/// with its resets marked, and — for a weekly window — what was spent per day.
class UsageHistoryPanel extends ConsumerStatefulWidget {
  const UsageHistoryPanel({
    required this.accountKey,
    required this.usage,
    required this.now,
    super.key,
  });

  final String accountKey;
  final AgentUsage usage;
  final DateTime now;

  @override
  ConsumerState<UsageHistoryPanel> createState() => _UsageHistoryPanelState();
}

class _UsageHistoryPanelState extends ConsumerState<UsageHistoryPanel> {
  String? _chosen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final history = ref.watch(
      usageHistoryProvider(usageHistoryQuery(widget.accountKey, widget.now)),
    );
    final measured = [
      for (final w in widget.usage.windows)
        if (w.percent != null) w,
    ];
    if (measured.isEmpty) return const SizedBox.shrink();
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final heading = theme.textTheme.labelMedium?.copyWith(
      fontWeight: FontWeight.w600,
    );

    final window = measured.firstWhere(
      (w) => w.label == _chosen,
      orElse: () => measured.first,
    );
    final range = usageChartRange(window.span);
    final end = widget.now;
    final start = end.subtract(range);
    final series = samplesOf(history, window.label, from: start);

    final weekly = measured.where((w) => w.span == kUsageSevenDayWindow);
    final weeklySamples = weekly.isEmpty
        ? const <UsageSample>[]
        : samplesOf(history, weekly.first.label);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('History', style: heading),
        const SizedBox(height: Insets.xs),
        if (measured.length > 1)
          Wrap(
            spacing: Insets.xs,
            runSpacing: Insets.xs,
            children: [
              for (final w in measured)
                ChoiceChip(
                  label: Text(w.label),
                  selected: w.label == window.label,
                  onSelected: (_) => setState(() => _chosen = w.label),
                ),
            ],
          ),
        const SizedBox(height: Insets.sm),
        if (series.length < 2)
          Text(
            series.isEmpty
                ? 'No history for ${window.label} yet. Each reading is kept '
                      'for 30 days, so the chart fills in as usage is checked.'
                : 'One reading of ${window.label} so far — the chart starts '
                      'with the next.',
            style: muted,
          )
        else
          TimeSeriesChart(
            points: [
              for (final s in series) TimeSeriesPoint(s.recordedAt, s.percent),
            ],
            start: start,
            end: end,
            maxY: math.max(100, series.map((s) => s.percent).reduce(math.max)),
            color: semantic.working,
            markers: [
              for (final reset in _resetsWithin(series))
                ChartMarker(reset, label: 'reset'),
            ],
            guides: const [100],
            // A gap longer than the idle ceiling plus slack is time nobody was
            // reading, not a straight line.
            breakAfter: const Duration(hours: 1),
            valueLabel: (v) => '${v.round()}%',
            timeLabel: (t) => formatResetClock(t, end),
            semanticsLabel: usageSeriesSummary(window.label, series, range),
          ),
        if (weeklySamples.length >= 2) ...[
          const SizedBox(height: Insets.md),
          Text('${weekly.first.label} spent per day', style: heading),
          const SizedBox(height: Insets.xs),
          _SpentPerDay(samples: weeklySamples, now: widget.now),
        ],
      ],
    );
  }
}

class _SpentPerDay extends StatelessWidget {
  const _SpentPerDay({required this.samples, required this.now});

  final List<UsageSample> samples;
  final DateTime now;

  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  Widget build(BuildContext context) {
    final spent = usageSpentPerDay(samples);
    final local = now.toLocal();
    final today = DateTime(local.year, local.month, local.day);
    final bars = [
      for (var i = 6; i >= 0; i--)
        () {
          final day = DateTime(today.year, today.month, today.day - i);
          final value = spent[day] ?? 0;
          return BarDatum(
            label: i == 0 ? 'Today' : _days[day.weekday - 1],
            value: value,
            valueLabel: '${value.toStringAsFixed(value < 10 ? 1 : 0)} points',
          );
        }(),
    ];
    final total = bars.fold<double>(0, (sum, b) => sum + b.value);
    return BarChart(
      bars: bars,
      color: SemanticColors.of(context).working,
      height: 96,
      semanticsLabel:
          'Spent per day over the last 7 days, ${total.round()} points in '
          'total, most on ${bars.reduce((a, b) => b.value > a.value ? b : a).label}',
    );
  }
}
