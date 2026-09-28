import 'dart:math' as math;

import 'package:agent_cli/usage.dart';
import 'package:flutter/material.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../usage_chip.dart'
    show formatResetClock, formatUsageDuration, onCourseToRunOut;
import '../usage_history_charts.dart' show samplesOf, usageSeriesSummary;
import '../usage_window_meter.dart';
import 'usage_tab_state.dart';

/// Where a window's line would go if spending carried on at its pace so far:
/// from the reading to the limit, when that comes first, or to the reset.
/// Empty when there is no pace to carry — no period, no reset, too early.
///
/// The same pace [usagePace] gives the meters, so the dashed line and the
/// sentence under the meter cannot disagree.
List<TimeSeriesPoint> usageForecastOf(UsageWindow window, DateTime readAt) {
  final percent = window.percent;
  final resetsAt = window.resetsAt;
  if (percent == null || resetsAt == null) return const [];
  final pace = usagePace(window, readAt);
  final projected = pace.projected;
  if (projected == null) return const [];
  final from = TimeSeriesPoint(readAt, percent);
  if (projected < 100) return [from, TimeSeriesPoint(resetsAt, projected)];
  final limitAt = pace.limitAt;
  if (limitAt == null || !limitAt.isBefore(resetsAt)) {
    return [from, TimeSeriesPoint(resetsAt, 100)];
  }
  return [from, TimeSeriesPoint(limitAt, 100)];
}

/// [forecast] cut at [end], so a projection days long does not squeeze the
/// recorded part of the chart into a sliver.
List<TimeSeriesPoint> clipForecast(
  List<TimeSeriesPoint> forecast,
  DateTime end,
) {
  if (forecast.length < 2) return forecast;
  final a = forecast.first;
  final b = forecast.last;
  if (!b.at.isAfter(end)) return forecast;
  if (!a.at.isBefore(end)) return const [];
  final share =
      end.difference(a.at).inMicroseconds /
      b.at.difference(a.at).inMicroseconds;
  return [a, TimeSeriesPoint(end, a.value + (b.value - a.value) * share)];
}

/// How many times [samples] reached a window's limit: each rise to 100% or
/// more from below it, and a first reading already there. **From recorded
/// readings only** — a limit reached and reset between two readings is not
/// seen, so the tile says "in recorded readings".
int usageLimitsHit(List<UsageSample> samples) {
  final byWindow = <String, List<UsageSample>>{};
  for (final sample in samples) {
    (byWindow[sample.windowLabel] ??= []).add(sample);
  }
  var hits = 0;
  for (final series in byWindow.values) {
    series.sort((a, b) => a.recordedAt.compareTo(b.recordedAt));
    var atLimit = false;
    for (final sample in series) {
      final now = sample.percent >= 100;
      if (now && !atLimit) hits++;
      atLimit = now;
    }
  }
  return hits;
}

/// **Each window of the account over the range**: its meter as the chip card
/// draws it, then the recorded line with its resets, the limit as a guide, and
/// the run-out forecast dashed ahead of it.
class UsageWindowsOverTime extends StatelessWidget {
  const UsageWindowsOverTime({
    required this.usage,
    required this.history,
    required this.range,
    required this.now,
    super.key,
  });

  final AgentUsage usage;
  final List<UsageSample> history;
  final UsageRange range;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final measured = [
      for (final w in usage.windows)
        if (w.percent != null) w,
    ];
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    if (measured.isEmpty) {
      return Text(
        'This account reports no quota windows, so there is nothing to chart.',
        style: muted,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, window) in measured.indexed) ...[
          if (i > 0) const SizedBox(height: Insets.lg),
          _WindowOverTime(
            window: window,
            readAt: usage.fetchedAt,
            history: history,
            range: range,
            now: now,
          ),
        ],
      ],
    );
  }
}

class _WindowOverTime extends StatelessWidget {
  const _WindowOverTime({
    required this.window,
    required this.readAt,
    required this.history,
    required this.range,
    required this.now,
  });

  final UsageWindow window;
  final DateTime readAt;
  final List<UsageSample> history;
  final UsageRange range;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final start = now.subtract(range.span);
    final series = samplesOf(history, window.label, from: start);
    // Ahead of now by at most half the range: enough to see where the line is
    // heading, not so much that the recorded part shrinks to nothing.
    final horizon = now.add(range.span ~/ 2);
    final forecast = usageForecastOf(window, readAt);
    final forecastEnd = forecast.isEmpty ? now : forecast.last.at;
    final end = forecastEnd.isAfter(horizon)
        ? horizon
        : (forecastEnd.isAfter(now) ? forecastEnd : now);
    final shown = clipForecast(forecast, end);
    final reset = window.resetsAt;
    final percent = window.percent!;
    final onCourse = onCourseToRunOut(
      percent: percent,
      span: window.span,
      resetsAt: reset,
      now: now,
    );
    final colour = usageSeverityColor(context, usageSeverityFor(percent));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        UsageWindowMeter(
          window: window,
          readAt: readAt,
          now: now,
          // The forecast sentence under the chart says it, with the dashes.
          showPace: false,
        ),
        const SizedBox(height: Insets.xs),
        if (series.length < 2)
          Text(
            series.isEmpty
                ? 'No readings of ${window.label} in ${range.phrase}. Each '
                      'reading is kept for 30 days, so the chart fills in as '
                      'usage is checked.'
                : 'One reading of ${window.label} in ${range.phrase} — the '
                      'chart starts with the next.',
            style: muted,
          )
        else
          TimeSeriesChart(
            points: [
              for (final s in series) TimeSeriesPoint(s.recordedAt, s.percent),
            ],
            forecast: shown,
            start: start,
            end: end,
            maxY: math.max(100, series.map((s) => s.percent).reduce(math.max)),
            color: colour,
            markers: [
              for (final at in _resetsWithin(series))
                ChartMarker(at, label: 'reset'),
              if (reset != null && reset.isAfter(now) && !reset.isAfter(end))
                ChartMarker(reset, label: 'resets'),
            ],
            guides: const [100],
            breakAfter: const Duration(hours: 1),
            height: 140,
            valueLabel: (v) => '${v.round()}%',
            timeLabel: (t) => formatResetClock(t, now),
            semanticsLabel: usageSeriesSummary(
              window.label,
              series,
              range.span,
            ),
          ),
        if (_forecastSentence() case final sentence?) ...[
          const SizedBox(height: Insets.xs),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                onCourse ? AppIcons.warning : AppIcons.clock,
                size: Chrome.iconSmall,
                color: onCourse
                    ? semantic.attention
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: Insets.xs),
              Expanded(
                child: Text(
                  sentence,
                  style: muted?.copyWith(
                    color: onCourse ? semantic.attention : null,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// The forecast in words, beside the dashes: when the limit arrives at this
  /// pace, or where the window ends. Null when there is no pace to speak of.
  String? _forecastSentence() {
    final reset = window.resetsAt;
    final forecast = usageForecastOf(window, readAt);
    if (reset == null || forecast.length < 2) return null;
    final last = forecast.last;
    if (last.value >= 100 && last.at.isBefore(reset)) {
      return 'At this pace it runs out at ${formatResetClock(last.at, now)}, '
          '${formatUsageDuration(reset.difference(last.at))} before it resets '
          '(${formatResetClock(reset, now)}).';
    }
    return 'At this pace it ends the window near ${last.value.round()}% '
        'when it resets (${formatResetClock(reset, now)}).';
  }
}

/// Moments a window reset between two samples: the earlier sample's reset,
/// whenever the next one names a later one.
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
