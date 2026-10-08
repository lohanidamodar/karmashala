import 'dart:math' as math;

import 'package:agent_cli/usage.dart';
import 'package:flutter/material.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../agents/presentation/usage_window_meter.dart';

/// What is printed where a route could not supply a number. A word, not a zero:
/// "0 tool calls" and "we were never told" are different claims.
const String kStatNotRecorded = 'not recorded';

/// The kinds a [TokenTally] splits into, in the order they are drawn.
enum TokenKind {
  input('Input'),
  output('Output'),
  cacheWrite('Cache write'),
  cacheRead('Cache read');

  const TokenKind(this.label);

  final String label;

  int? of(TokenTally tally) => switch (this) {
    input => tally.input,
    output => tally.output,
    cacheWrite => tally.cacheCreated,
    cacheRead => tally.cacheRead,
  };
}

/// The share of everything sent to the model that was read back from cache:
/// cache read over input, cache write and cache read. Null unless both input
/// and cache read were recorded — a missing bucket would inflate the share.
double? cacheReadShare(TokenTally tally) {
  final input = tally.input, read = tally.cacheRead;
  if (input == null || read == null) return null;
  final sent = input + read + (tally.cacheCreated ?? 0);
  return sent <= 0 ? null : read / sent;
}

/// How full the context was at the newest call, or null unless both the
/// prompt size and the window were recorded.
double? contextFill(SessionStats stats) {
  final used = stats.lastPromptTokens, window = stats.contextWindow;
  if (used == null || window == null || window <= 0) return null;
  return used / window;
}

/// Tool calls by name, most first (ties by name), cut to [limit].
({List<(String, int)> top, int otherTools, int otherCalls, int unnamed})
rankToolCalls(Map<String, int> byName, int? total, {int limit = 6}) {
  final sorted = byName.entries.toList()
    ..sort((a, b) {
      final byCount = b.value.compareTo(a.value);
      return byCount != 0 ? byCount : a.key.compareTo(b.key);
    });
  final top = [for (final e in sorted.take(limit)) (e.key, e.value)];
  final rest = sorted.skip(limit);
  final named = sorted.fold<int>(0, (sum, e) => sum + e.value);
  return (
    top: top,
    otherTools: rest.length,
    otherCalls: rest.fold<int>(0, (sum, e) => sum + e.value),
    unnamed: total == null ? 0 : math.max(0, total - named),
  );
}

/// The turn with the most output (the first, on a tie) and its count.
({int turn, int tokens})? peakTurn(List<int> perTurn) {
  if (perTurn.isEmpty) return null;
  var best = 0;
  for (var i = 1; i < perTurn.length; i++) {
    if (perTurn[i] > perTurn[best]) best = i;
  }
  return (turn: best + 1, tokens: perTurn[best]);
}

/// A per-turn chart's peak and average in words. [perTurn] must not be empty.
String perTurnSummary(List<int> perTurn) {
  final peak = peakTurn(perTurn)!;
  final total = perTurn.fold<int>(0, (sum, v) => sum + v);
  return 'Peak ${formatCompactCount(peak.tokens)} at turn ${peak.turn} of '
      '${perTurn.length} · average '
      '${formatCompactCount((total / perTurn.length).round())}';
}

/// A context-per-turn chart's latest and peak in words. [perTurn] must not
/// be empty.
String contextPerTurnSummary(List<int> perTurn) {
  final peak = peakTurn(perTurn)!;
  return 'Latest ${formatCompactCount(perTurn.last)} at turn '
      '${perTurn.length} · peak ${formatCompactCount(peak.tokens)} at turn '
      '${peak.turn}';
}

/// A cost as the agent reported it: its own amount and currency, never a
/// figure worked out here. A fraction of a cent keeps its digits.
String formatReportedCost(ReportedCost cost) {
  final amount = cost.amount;
  final digits = amount != 0 && amount.abs() < 0.01 ? 4 : 2;
  final currency = cost.currency.trim();
  return currency.isEmpty
      ? amount.toStringAsFixed(digits)
      : '${amount.toStringAsFixed(digits)} $currency';
}

/// How a per-turn chart's output divides where the agent breaks thinking out:
/// the answer and the thinking, each with its share of the output. Thinking is
/// a part of output, so it is drawn in output's own hue, lighter — the same
/// way [Sparkline] draws its band.
List<BarSegment> thinkingSegments(
  BuildContext context,
  List<int> output,
  List<int> reasoning,
) {
  final total = output.fold<int>(0, (sum, v) => sum + v);
  var thinking = 0;
  for (var i = 0; i < output.length && i < reasoning.length; i++) {
    thinking += math.min(reasoning[i], output[i]);
  }
  return thinkingSplitSegments(context, output: total, thinking: thinking);
}

/// [thinkingSegments] for totals: [thinking] is the part of [output] that was
/// reasoning.
List<BarSegment> thinkingSplitSegments(
  BuildContext context, {
  required int output,
  required int thinking,
}) {
  final total = output;
  final answer = total - thinking;
  final hue = tokenKindColor(context, TokenKind.output);
  String? share(int part) => total <= 0 ? null : formatShare(part, total);
  return [
    BarSegment(
      label: 'Answer',
      value: answer,
      color: hue,
      valueLabel: formatCompactCount(answer),
      detail: share(answer),
    ),
    BarSegment(
      label: 'Thinking',
      value: thinking,
      color: hue.withValues(alpha: kThinkingBandAlpha),
      valueLabel: formatCompactCount(thinking),
      detail: share(thinking),
    ),
  ];
}

/// The share of the output hue the thinking band and its swatch are drawn at.
const double kThinkingBandAlpha = SparklinePainter.bandAlpha;

/// The thinking part of a per-turn chart in words, for its screen reader.
String thinkingSummary(List<BarSegment> segments) {
  final thinking = segments.last;
  final detail = thinking.detail;
  return 'Thinking ${thinking.valueLabel}'
      '${detail == null ? '' : ' ($detail)'} of output.';
}

/// A tally in words, for a screen reader: every kind, recorded or not.
String tokenSplitSummary(TokenTally tally) {
  final total = tally.total;
  final parts = [
    for (final kind in TokenKind.values)
      switch (kind.of(tally)) {
        null => '${kind.label.toLowerCase()} $kStatNotRecorded',
        final value =>
          '${kind.label.toLowerCase()} ${formatCompactCount(value)}'
              '${total == null ? '' : ' (${formatShare(value, total)})'}',
      },
  ];
  return 'Tokens by kind: ${parts.join(', ')}';
}

/// The colour each kind is drawn in. Semantic hues only; cache read — usually
/// most of the bar — is the quietest.
Color tokenKindColor(BuildContext context, TokenKind kind) {
  final semantic = SemanticColors.of(context);
  final scheme = Theme.of(context).colorScheme;
  return switch (kind) {
    TokenKind.input => semantic.working,
    TokenKind.output => semantic.idle,
    TokenKind.cacheWrite => semantic.neutral,
    TokenKind.cacheRead => scheme.onSurfaceVariant.withValues(alpha: 0.35),
  };
}

/// A section heading inside the dialog, with an optional muted line under it.
class StatsSectionHeading extends StatelessWidget {
  const StatsSectionHeading(
    this.label, {
    this.detail,
    this.first = false,
    super.key,
  });

  final String label;
  final String? detail;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(top: first ? 0 : Insets.lg, bottom: Insets.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(header: true, child: EyebrowLabel(label)),
          if (detail case final line?)
            Padding(
              padding: const EdgeInsets.only(top: Insets.xxs),
              child: Text(
                line,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A smaller heading for a block inside a section.
class StatsBlockLabel extends StatelessWidget {
  const StatsBlockLabel(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: Insets.md, bottom: Insets.xs),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// A muted sentence under a chart.
class StatsNote extends StatelessWidget {
  const StatsNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: Insets.xs),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// A tally as one bar split by kind, its legend, and — where the agent breaks
/// it out — how much of the output was reasoning.
class TokenSplit extends StatelessWidget {
  const TokenSplit({required this.tally, super.key});

  final TokenTally tally;

  @override
  Widget build(BuildContext context) {
    final total = tally.total;
    final segments = [
      for (final kind in TokenKind.values)
        BarSegment(
          label: kind.label,
          value: kind.of(tally),
          color: tokenKindColor(context, kind),
          valueLabel: switch (kind.of(tally)) {
            null => null,
            final v => formatCompactCount(v),
          },
          detail: switch ((kind.of(tally), total)) {
            (final v?, final t?) => formatShare(v, t),
            _ => null,
          },
        ),
    ];
    final reasoning = tally.reasoning;
    final output = tally.output;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SegmentedBar(
          segments: segments,
          semanticsLabel: tokenSplitSummary(tally),
        ),
        const SizedBox(height: Insets.sm),
        ChartLegend(segments: segments, unrecordedLabel: kStatNotRecorded),
        if (reasoning != null)
          StatsNote(
            'Of the output, ${formatCompactCount(reasoning)} was reasoning'
            '${output == null || output <= 0 ? '' : ' (${formatShare(reasoning, output)})'}'
            '.',
          ),
      ],
    );
  }
}

/// A label, a meter and its number on one line; the label goes above the
/// meter when the line is too narrow for both.
class StatsMeterRow extends StatelessWidget {
  const StatsMeterRow({
    required this.label,
    required this.value,
    required this.valueLabel,
    required this.color,
    required this.semanticsLabel,
    super.key,
  });

  final String label;
  final double value;
  final String valueLabel;
  final Color color;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme.bodySmall;
    final number = ExcludeSemantics(
      child: Text(
        valueLabel,
        style: text?.copyWith(
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
    final meter = LinearMeter(
      value: value,
      color: color,
      semanticsLabel: semanticsLabel,
    );
    return StatsMeterLayout(
      label: ExcludeSemantics(child: Text(label, style: text)),
      meter: meter,
      number: number,
    );
  }
}

/// [StatsMeterRow]'s layout: one line when there is room, label over meter
/// when there is not.
class StatsMeterLayout extends StatelessWidget {
  const StatsMeterLayout({
    required this.label,
    required this.meter,
    required this.number,
    super.key,
  });

  final Widget label;
  final Widget meter;
  final Widget number;

  static const double _stackBelow = 360;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow =
            constraints.maxWidth <
            WidthClass.scaleBreakpoint(_stackBelow, scaler);
        if (narrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(child: label),
                  const SizedBox(width: Insets.sm),
                  number,
                ],
              ),
              meter,
            ],
          );
        }
        return Row(
          children: [
            Expanded(flex: 2, child: label),
            const SizedBox(width: Insets.sm),
            Expanded(flex: 3, child: meter),
            const SizedBox(width: Insets.sm),
            number,
          ],
        );
      },
    );
  }
}

/// How much was read from cache, as a meter.
class CacheReadMeter extends StatelessWidget {
  const CacheReadMeter({required this.share, super.key});

  final double share;

  @override
  Widget build(BuildContext context) {
    final percent = '${(share * 100).round()}%';
    return StatsMeterRow(
      label: 'Read from cache',
      value: share,
      valueLabel: percent,
      color: SemanticColors.of(context).working,
      semanticsLabel:
          'Read from cache: $percent of the tokens sent were cache reads',
    );
  }
}

/// How full the context was at the newest call, as a meter where the window
/// is known and as words where it is not.
class ContextUsage extends StatelessWidget {
  const ContextUsage({required this.stats, required this.agentName, super.key});

  final SessionStats stats;
  final String agentName;

  @override
  Widget build(BuildContext context) {
    final used = stats.lastPromptTokens, window = stats.contextWindow;
    final agent = agentName.isEmpty ? 'this agent' : agentName;
    final fill = contextFill(stats);
    if (fill != null) {
      final percent = fill * 100;
      final words =
          '${formatCompactCount(used!)} of ${formatCompactCount(window!)}';
      return StatsMeterRow(
        label: 'Newest request',
        value: fill,
        valueLabel: '$words · ${percent.round()}%',
        color: usageSeverityColor(context, usageSeverityFor(percent)),
        semanticsLabel:
            'Context: the newest request sent $words tokens of the window, '
            '${percent.round()}%',
      );
    }
    return StatsNote(switch ((used, window)) {
      (final u?, null) =>
        'The newest request sent ${formatCompactCount(u)} tokens. The '
            'context window size is $kStatNotRecorded by $agent.',
      (null, final w?) =>
        'Context window ${formatCompactCount(w)} tokens. The size of the '
            'newest request is $kStatNotRecorded.',
      _ => 'Context use is $kStatNotRecorded.',
    });
  }
}

/// Output tokens per turn as a sparkline, with the peak in words — and, where
/// the agent breaks thinking out, the thinking as a band under the line with
/// a legend saying how the output divided.
class OutputPerTurn extends StatelessWidget {
  const OutputPerTurn({
    required this.perTurn,
    this.reasoningPerTurn,
    super.key,
  });

  final List<int> perTurn;

  /// In step with [perTurn]; null where thinking was not recorded.
  final List<int>? reasoningPerTurn;

  @override
  Widget build(BuildContext context) {
    final summary = perTurnSummary(perTurn);
    final reasoning = reasoningPerTurn;
    final segments = reasoning == null
        ? null
        : thinkingSegments(context, perTurn, reasoning);
    final hue = tokenKindColor(context, TokenKind.output);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Sparkline(
          values: [for (final v in perTurn) v.toDouble()],
          secondaryValues: reasoning == null
              ? null
              : [for (final v in reasoning) v.toDouble()],
          secondaryColor: hue,
          color: hue,
          height: 36,
          semanticsLabel:
              'Output tokens per turn. $summary'
              '${segments == null ? '' : '. ${thinkingSummary(segments)}'}',
        ),
        ExcludeSemantics(child: StatsNote(summary)),
        if (segments != null) ...[
          const SizedBox(height: Insets.xs),
          ExcludeSemantics(child: ChartLegend(segments: segments)),
        ],
      ],
    );
  }
}

/// Tokens in the agent's context as each turn ended, as a sparkline with the
/// latest and the peak in words — what an agent reporting over its protocol
/// gives instead of output per turn.
class ContextPerTurn extends StatelessWidget {
  const ContextPerTurn({required this.perTurn, super.key});

  final List<int> perTurn;

  @override
  Widget build(BuildContext context) {
    final summary = contextPerTurnSummary(perTurn);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Sparkline(
          values: [for (final v in perTurn) v.toDouble()],
          color: tokenKindColor(context, TokenKind.input),
          height: 36,
          semanticsLabel: 'Context in use per turn. $summary',
        ),
        ExcludeSemantics(child: StatsNote(summary)),
      ],
    );
  }
}

/// Tokens per model, largest first.
class TokensByModel extends StatelessWidget {
  const TokensByModel({required this.byModel, super.key});

  final Map<String, TokenTally> byModel;

  @override
  Widget build(BuildContext context) {
    final entries = [
      for (final MapEntry(:key, :value) in byModel.entries)
        (key, value.total ?? 0),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    final whole = entries.fold<int>(0, (sum, e) => sum + e.$2);
    return RankedBars(
      color: SemanticColors.of(context).working,
      bars: [
        for (final (model, tokens) in entries)
          BarDatum(
            label: model,
            value: tokens.toDouble(),
            valueLabel:
                '${formatCompactCount(tokens)} · ${formatShare(tokens, whole) ?? '0%'}',
          ),
      ],
    );
  }
}

/// Tool calls by name, most first, with what did not make the cut in words.
class ToolCallsByName extends StatelessWidget {
  const ToolCallsByName({required this.byName, required this.total, super.key});

  final Map<String, int> byName;
  final int? total;

  @override
  Widget build(BuildContext context) {
    final ranked = rankToolCalls(byName, total);
    String calls(int n) => '$n ${n == 1 ? 'call' : 'calls'}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        RankedBars(
          color: SemanticColors.of(context).working,
          bars: [
            for (final (name, count) in ranked.top)
              BarDatum(
                label: name,
                value: count.toDouble(),
                valueLabel: formatCompactCount(count),
              ),
          ],
        ),
        if (ranked.otherTools > 0)
          StatsNote(
            '${ranked.otherTools} more '
            '${ranked.otherTools == 1 ? 'tool' : 'tools'}, '
            '${calls(ranked.otherCalls)}.',
          ),
        if (ranked.unnamed > 0)
          StatsNote('${calls(ranked.unnamed)} with no tool name recorded.'),
      ],
    );
  }
}
