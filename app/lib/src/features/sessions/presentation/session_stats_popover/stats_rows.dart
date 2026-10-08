// The popover rows: group labels, context header, figures and bars.

part of '../session_stats_popover.dart';

/// An 11px uppercase group label, with the air above it that separates one
/// group of the card from the last.
class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: EyebrowLabel(
      text,
      maxLines: 1,
      padding: const EdgeInsets.only(top: Insets.md, bottom: Insets.xs),
    ),
  );
}

/// How full the context was at the newest request — the percentage, a meter in
/// the usage severity colours, and about how many turns are left — or, where
/// the prompt or the window was not recorded, a sentence saying which.
class _ContextHeader extends StatelessWidget {
  const _ContextHeader({
    required this.stats,
    required this.agentName,
    required this.meta,
  });

  final SessionStats stats;
  final String agentName;
  final TextStyle? meta;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fill = contextFill(stats);
    if (fill == null) {
      final agent = agentName.isEmpty ? 'this agent' : agentName;
      return Text(switch ((stats.lastPromptTokens, stats.contextWindow)) {
        (final u?, null) =>
          'The newest request sent ${formatCompactCount(u)} tokens. The '
              'context window is $kStatNotRecorded by $agent, so neither the '
              'share used nor the turns left can be said.',
        (null, final w?) =>
          'Context window ${formatCompactCount(w)} tokens. The size of the '
              'newest request is $kStatNotRecorded, so turns left cannot be '
              'said.',
        _ => 'Context use and turns left are $kStatNotRecorded.',
      }, style: meta);
    }
    final percent = fill * 100;
    final color = usageSeverityColor(context, usageSeverityFor(percent));
    final used = formatCompactCount(stats.lastPromptTokens!);
    final window = formatCompactCount(stats.contextWindow!);
    final left = turnsLeftEstimate(stats);
    final leftWords = switch (left) {
      null => 'turns left $kStatNotRecorded — too few turns to estimate',
      0 => 'no turns left',
      1 => 'about 1 turn left',
      final n => 'about ${formatStatCount(n)} turns left',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              '${percent.round()}%',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: Text(
                'context used · $used of $window',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: meta?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: Insets.xs),
        LinearMeter(
          value: fill,
          color: color,
          semanticsLabel:
              'Context: the newest request sent $used of $window tokens, '
              '${percent.round()}%; $leftWords',
        ),
        const SizedBox(height: Insets.xs),
        ExcludeSemantics(
          child: Text(
            left == null
                ? '${leftWords[0].toUpperCase()}${leftWords.substring(1)}.'
                : '${leftWords[0].toUpperCase()}${leftWords.substring(1)} '
                      'at this session’s average growth per turn.',
            style: meta,
          ),
        ),
      ],
    );
  }
}

/// Turns, tool calls, tokens and elapsed, side by side.
class _FigureRow extends StatelessWidget {
  const _FigureRow({required this.stats, required this.meta});

  final SessionStats stats;
  final TextStyle? meta;

  @override
  Widget build(BuildContext context) {
    final total = stats.tokens.total;
    final span = stats.span;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _Figure(
            label: 'Turns',
            value: stats.turns == null ? null : formatStatCount(stats.turns),
            meta: meta,
          ),
        ),
        Expanded(
          child: _Figure(
            label: 'Tool calls',
            value: stats.toolCalls == null
                ? null
                : formatStatCount(stats.toolCalls),
            meta: meta,
          ),
        ),
        Expanded(
          child: _Figure(
            label: 'Tokens',
            value: total == null ? null : formatCompactCount(total),
            meta: meta,
          ),
        ),
        Expanded(
          child: Tooltip(
            message: 'First record to last, not time spent working.',
            child: _Figure(
              label: 'Elapsed',
              value: span == null ? null : formatStatSpan(span),
              meta: meta,
            ),
          ),
        ),
      ],
    );
  }
}

/// One figure: its number (or "not recorded", smaller and muted) over its
/// label.
class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value, required this.meta});

  final String label;
  final String? value;
  final TextStyle? meta;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = this.value;
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.only(right: Insets.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              value ?? kStatNotRecorded,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: value == null
                  ? meta
                  : theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
            ),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: meta,
            ),
          ],
        ),
      ),
    );
  }
}

/// One small bar per kind — input, output, cache read, cache write — scaled
/// to the largest; a kind that was not recorded gets words and no bar.
class _TokensByKind extends StatelessWidget {
  const _TokensByKind({required this.tally, required this.meta});

  final TokenTally tally;
  final TextStyle? meta;

  static const _order = [
    TokenKind.input,
    TokenKind.output,
    TokenKind.cacheRead,
    TokenKind.cacheWrite,
  ];

  @override
  Widget build(BuildContext context) {
    final total = tally.total;
    final top = _order
        .map((k) => k.of(tally) ?? 0)
        .fold<int>(0, (m, v) => math.max(m, v));
    final reasoning = tally.reasoning, output = tally.output;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final kind in _order)
          _BarRow(
            label: kind.label,
            swatch: tokenKindColor(context, kind),
            fraction: switch (kind.of(tally)) {
              null => null,
              final v => top <= 0 ? 0 : v / top,
            },
            valueLabel: switch (kind.of(tally)) {
              null => null,
              final v =>
                total == null || total <= 0
                    ? formatCompactCount(v)
                    : '${formatCompactCount(v)} · '
                          '${formatShare(v, total) ?? '0%'}',
            },
            meta: meta,
          ),
        if (reasoning != null)
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs),
            child: Text(
              'Of the output, ${formatCompactCount(reasoning)} was reasoning'
              '${output == null || output <= 0 ? '' : ' (${formatShare(reasoning, output)})'}'
              '.',
              style: meta,
            ),
          ),
      ],
    );
  }
}

/// A label, a meter and its number on one 22px line — or the label and "not
/// recorded" where [fraction] is null, since an empty bar would read as zero.
class _BarRow extends StatelessWidget {
  const _BarRow({
    required this.label,
    required this.swatch,
    required this.fraction,
    required this.valueLabel,
    required this.meta,
  });

  final String label;
  final Color swatch;
  final double? fraction;
  final String? valueLabel;
  final TextStyle? meta;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fraction = this.fraction;
    final spoken = '$label: ${valueLabel ?? kStatNotRecorded}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xxs),
      child: MergeSemantics(
        child: Row(
          children: [
            SizedBox(
              width: 88,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
            const SizedBox(width: Insets.sm),
            if (fraction == null)
              Expanded(
                child: Semantics(
                  label: spoken,
                  excludeSemantics: true,
                  child: Text(kStatNotRecorded, style: meta),
                ),
              )
            else ...[
              Expanded(
                child: LinearMeter(
                  value: fraction,
                  color: swatch,
                  semanticsLabel: spoken,
                ),
              ),
              const SizedBox(width: Insets.sm),
              ExcludeSemantics(
                child: Text(
                  valueLabel!,
                  maxLines: 1,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The busiest tools as bars, and what did not make the cut in words.
class _ToolCalls extends StatelessWidget {
  const _ToolCalls({
    required this.byName,
    required this.total,
    required this.meta,
  });

  final Map<String, int> byName;
  final int? total;
  final TextStyle? meta;

  @override
  Widget build(BuildContext context) {
    final ranked = rankToolCalls(byName, total, limit: _topTools);
    String calls(int n) => '$n ${n == 1 ? 'call' : 'calls'}';
    // RankedBars is rows of Text and painted meters — nothing in it asks its
    // constraints, so the menu's intrinsic questions are answered.
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
          Text(
            '${ranked.otherTools} more '
            '${ranked.otherTools == 1 ? 'tool' : 'tools'}, '
            '${calls(ranked.otherCalls)}.',
            style: meta,
          ),
        if (ranked.unnamed > 0)
          Text(
            '${calls(ranked.unnamed)} with no tool name recorded.',
            style: meta,
          ),
      ],
    );
  }
}

/// Output tokens per turn as a sparkline, with the peak and average in words,
/// and the thinking band and legend where the agent breaks thinking out.
/// [Sparkline] sizes itself with a LimitedBox, not a LayoutBuilder, so it is
/// safe here as it stands; the legend is a [Wrap] of text.
class _OutputPerTurn extends StatelessWidget {
  const _OutputPerTurn({
    required this.perTurn,
    required this.reasoningPerTurn,
    required this.meta,
  });

  final List<int> perTurn;
  final List<int>? reasoningPerTurn;
  final TextStyle? meta;

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
          height: 32,
          semanticsLabel:
              'Output tokens per turn. $summary'
              '${segments == null ? '' : '. ${thinkingSummary(segments)}'}',
        ),
        const SizedBox(height: Insets.xs),
        ExcludeSemantics(child: Text(summary, style: meta)),
        if (segments != null) ...[
          const SizedBox(height: Insets.xs),
          ExcludeSemantics(child: ChartLegend(segments: segments)),
        ],
      ],
    );
  }
}
