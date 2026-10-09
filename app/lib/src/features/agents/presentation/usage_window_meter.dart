import 'package:agent_cli/usage.dart';
import 'package:flutter/material.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/usage_forecast.dart';
import 'usage_chip.dart' show formatResetClock, formatUsageDuration;

/// **The forecast in words**, the one sentence the popover, the Usage tab and
/// the glance all say: "At this pace: runs out ~14:20 (in 1h10m), before the
/// reset at 15:04", "Lasts until the reset at 15:04", "Idle", or why there is
/// no forecast.
String usageForecastSentence(UsageForecast forecast, DateTime now) {
  final reset = forecast.resetsAt;
  final atReset = reset == null ? '' : ' at ${formatResetClock(reset, now)}';
  switch (forecast.kind) {
    case UsageForecastKind.notMeasured:
      return 'Forecast: not measured';
    case UsageForecastKind.notEnoughData:
      return 'Forecast: not enough data yet';
    case UsageForecastKind.idle:
      return 'Idle — nothing spent in the last hour';
    case UsageForecastKind.spent:
      return 'Limit reached${reset == null ? '' : ' — resets$atReset'}';
    case UsageForecastKind.lastsUntilReset:
      return reset == null
          ? 'At this pace: lasts until the reset'
          : 'At this pace: lasts until the reset$atReset';
    case UsageForecastKind.runsOut:
      final out = forecast.runsOutAt!;
      final when =
          '~${formatResetClock(out, now)} '
          '(in ${formatUsageDuration(out.difference(now))})';
      return 'At this pace: runs out $when'
          '${reset == null ? '' : ', before the reset$atReset'}';
  }
}

/// The colour a forecast's sentence is drawn in: the warning colour when it
/// runs out well before its reset, failure when spent, muted otherwise.
Color usageForecastColor(BuildContext context, UsageForecast forecast) {
  final semantic = SemanticColors.of(context);
  if (forecast.kind == UsageForecastKind.spent) return semantic.failure;
  if (forecast.warns()) return semantic.attention;
  return Theme.of(context).colorScheme.onSurfaceVariant;
}

IconData usageForecastIcon(UsageForecast forecast) => switch (forecast.kind) {
  UsageForecastKind.spent => AppIcons.warning,
  UsageForecastKind.runsOut when forecast.warns() => AppIcons.warning,
  UsageForecastKind.idle ||
  UsageForecastKind.lastsUntilReset => AppIcons.checkCircle,
  _ => AppIcons.clock,
};

/// The forecast's dashed line on the shared chart: from the reading to the
/// run-out or the reset, whichever comes first. Empty when there is no rate.
List<TimeSeriesPoint> usageForecastLine(UsageForecast forecast) {
  final from = forecast.readAt;
  final end = forecast.end;
  final percent = forecast.percent;
  if (forecast.ratePerHour == null ||
      from == null ||
      end == null ||
      percent == null ||
      !end.isAfter(from)) {
    return const [];
  }
  return [
    TimeSeriesPoint(from, percent),
    TimeSeriesPoint(end, forecast.valueAt(end)),
  ];
}

/// The band around [usageForecastLine]: the slower and faster rates the
/// recent readings allow, to the same end.
List<TimeSeriesBandPoint> usageForecastBand(UsageForecast forecast) {
  final line = usageForecastLine(forecast);
  final low = forecast.lowRatePerHour;
  final high = forecast.highRatePerHour;
  if (line.length < 2 || low == null || high == null) return const [];
  final from = line.first;
  final to = line.last.at;
  // Points between, so a band that meets the limit bends there.
  return [
    for (var i = 0; i <= 8; i++)
      () {
        final at = from.at.add(to.difference(from.at) * (i / 8));
        return TimeSeriesBandPoint(
          at,
          forecast.valueAt(at, rate: low),
          forecast.valueAt(at, rate: high),
        );
      }(),
  ];
}

/// The colour a severity is drawn in. Semantic, never the accent: a quota meter
/// is status, and the accent is for selection and focus.
Color usageSeverityColor(BuildContext context, UsageSeverity severity) {
  final semantic = SemanticColors.of(context);
  return switch (severity) {
    UsageSeverity.ok => semantic.idle,
    UsageSeverity.attention => semantic.attention,
    UsageSeverity.failure => semantic.failure,
    UsageSeverity.unknown => semantic.neutral,
  };
}

/// `62% · resets in 2h11m (14:30)` — the numbers of one window, in words.
String usageWindowFacts(UsageWindow window, DateTime now) {
  final percent = window.percent;
  if (percent == null) return kUsageNoQuotaReported;
  final reset = window.resetsAt;
  return reset == null
      ? '${percent.round()}%'
      : '${percent.round()}% · resets in '
            '${formatUsageDuration(reset.difference(now))} '
            '(${formatResetClock(reset, now)})';
}

/// What the pace means for the reader, or null when there is nothing to say.
String? usagePaceSentence(UsagePace pace, DateTime now) {
  final limitAt = pace.limitAt;
  String runsOut() => limitAt == null
      ? ''
      : ' — runs out in ${formatUsageDuration(limitAt.difference(now))} '
            '(${formatResetClock(limitAt, now)}) at this rate';
  return switch (pace.verdict) {
    UsagePaceVerdict.unknown => null,
    UsagePaceVerdict.onPace => 'Within pace',
    UsagePaceVerdict.aheadOfPace => 'Slightly ahead of pace',
    UsagePaceVerdict.overPace => 'Over pace${runsOut()}',
    UsagePaceVerdict.spent => 'Limit reached',
  };
}

/// One quota window: its name and numbers, a meter whose tick marks where an
/// even rate would be by now, and a line saying how the pace compares.
class UsageWindowMeter extends StatelessWidget {
  const UsageWindowMeter({
    required this.window,
    required this.readAt,
    required this.now,
    this.trailing,
    this.showPace = true,
    this.forecast,
    super.key,
  });

  /// When given, its sentence is said in place of the pace's: the recent
  /// rate rather than the average since the window opened.
  final UsageForecast? forecast;

  final UsageWindow window;

  /// When the reading was taken — the moment the percentage is true at.
  final DateTime readAt;

  /// The app clock, for countdowns.
  final DateTime now;

  /// Beside the pace line — a sparkline, say.
  final Widget? trailing;
  final bool showPace;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final small = theme.textTheme.bodySmall;
    final percent = window.percent;
    if (percent == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Insets.xs),
        child: Row(
          children: [
            Expanded(child: Text(window.label, style: small)),
            Text(
              kUsageNoQuotaReported,
              style: small?.copyWith(color: semantic.neutral),
            ),
          ],
        ),
      );
    }
    final pace = usagePace(window, readAt);
    final colour = usageSeverityColor(context, usageSeverityFor(percent));
    final facts = usageWindowFacts(window, now);
    final ahead = forecast;
    final sentence = !showPace
        ? null
        : ahead != null
        ? usageForecastSentence(ahead, now)
        : usagePaceSentence(pace, now);
    final paceColour = ahead != null
        ? usageForecastColor(context, ahead)
        : switch (pace.verdict) {
            UsagePaceVerdict.overPace ||
            UsagePaceVerdict.aheadOfPace => semantic.attention,
            UsagePaceVerdict.spent => semantic.failure,
            _ => theme.colorScheme.onSurfaceVariant,
          };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: Insets.sm,
            children: [
              Text(
                window.label,
                style: small?.copyWith(fontWeight: FontWeight.w600),
              ),
              Text(
                facts,
                style: small?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: Insets.xxs),
          LinearMeter(
            value: percent / 100,
            marker: pace.elapsed,
            color: colour,
            semanticsLabel:
                '${window.label}: $facts'
                '${sentence == null ? '' : '. $sentence'}',
          ),
          if (sentence != null || trailing != null)
            Row(
              children: [
                if (sentence != null) ...[
                  Icon(
                    ahead != null
                        ? usageForecastIcon(ahead)
                        : switch (pace.verdict) {
                            UsagePaceVerdict.onPace => AppIcons.checkCircle,
                            _ => AppIcons.warning,
                          },
                    size: Chrome.iconSmall,
                    color: paceColour,
                  ),
                  const SizedBox(width: Insets.xs),
                ],
                Expanded(
                  child: Text(
                    sentence ?? '',
                    style: small?.copyWith(color: paceColour),
                  ),
                ),
                if (trailing case final trailing?) ...[
                  const SizedBox(width: Insets.sm),
                  trailing,
                ],
              ],
            ),
        ],
      ),
    );
  }
}
