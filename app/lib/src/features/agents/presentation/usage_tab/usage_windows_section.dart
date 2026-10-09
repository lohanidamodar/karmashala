import 'dart:math' as math;

import 'package:agent_cli/usage.dart';
import 'package:flutter/material.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../application/usage_forecast.dart';
import '../usage_chip.dart' show formatResetClock;
import '../usage_history_charts.dart' show samplesOf, usageSeriesSummary;
import '../usage_window_meter.dart';
import 'usage_tab_state.dart';

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

/// [band] without its points past [end].
List<TimeSeriesBandPoint> clipBand(
  List<TimeSeriesBandPoint> band,
  DateTime end,
) {
  final kept = [
    for (final p in band)
      if (!p.at.isAfter(end)) p,
  ];
  return kept.length < 2 ? const [] : kept;
}

/// Where a window's chart ends: the forecast's end when it comes before
/// [horizon], else [horizon], and never before [now].
DateTime usageChartEnd(
  UsageForecast? forecast,
  DateTime now,
  DateTime horizon,
) {
  final line = forecast == null
      ? const <TimeSeriesPoint>[]
      : usageForecastLine(forecast);
  final forecastEnd = line.isEmpty ? now : line.last.at;
  if (forecastEnd.isAfter(horizon)) return horizon;
  return forecastEnd.isAfter(now) ? forecastEnd : now;
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
/// the forecast at the recent pace dashed ahead of it, inside its band.
class UsageWindowsOverTime extends StatelessWidget {
  const UsageWindowsOverTime({
    required this.usage,
    required this.history,
    required this.range,
    required this.now,
    this.forecasts = const {},
    super.key,
  });

  final AgentUsage usage;
  final List<UsageSample> history;
  final UsageRange range;
  final DateTime now;

  /// [usageForecastsProvider]'s answer for the account, by window label; a
  /// window missing from it is forecast from [history] by the same function.
  final Map<String, UsageForecast> forecasts;

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
        'This account reports no quota windows, so there is nothing to '
        'chart or forecast — not measured.',
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
            forecast:
                forecasts[window.label] ??
                usageForecastFor(
                  window,
                  readAt: usage.fetchedAt,
                  samples: history,
                ),
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
    required this.forecast,
  });

  final UsageWindow window;
  final DateTime readAt;
  final List<UsageSample> history;
  final UsageRange range;
  final DateTime now;
  final UsageForecast forecast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final start = now.subtract(range.span);
    final series = samplesOf(history, window.label, from: start);
    // Ahead of now by at most half the range: enough to see where the line is
    // heading, not so much that the recorded part shrinks to nothing.
    final end = usageChartEnd(forecast, now, now.add(range.span ~/ 2));
    final reset = window.resetsAt;
    final percent = window.percent!;
    final colour = usageSeverityColor(context, usageSeverityFor(percent));
    final sentenceColour = usageForecastColor(context, forecast);

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
            forecast: clipForecast(usageForecastLine(forecast), end),
            forecastBand: clipBand(usageForecastBand(forecast), end),
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
        const SizedBox(height: Insets.xs),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              usageForecastIcon(forecast),
              size: Chrome.iconSmall,
              color: sentenceColour,
            ),
            const SizedBox(width: Insets.xs),
            Expanded(
              child: Text(
                usageForecastSentence(forecast, now),
                key: ValueKey('usage-forecast-${window.label}'),
                style: muted?.copyWith(color: sentenceColour),
              ),
            ),
          ],
        ),
      ],
    );
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
