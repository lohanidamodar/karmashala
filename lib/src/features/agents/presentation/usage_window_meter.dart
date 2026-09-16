import 'package:agent_cli/usage.dart';
import 'package:flutter/material.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../domain/usage_pace.dart';
import 'usage_chip.dart' show formatResetClock, formatUsageDuration;

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
    super.key,
  });

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
    final sentence = showPace ? usagePaceSentence(pace, now) : null;
    final paceColour = switch (pace.verdict) {
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
          const SizedBox(height: 2),
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
                    switch (pace.verdict) {
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
