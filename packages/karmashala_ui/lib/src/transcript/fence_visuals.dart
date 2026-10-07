import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

import '../app_icons.dart';
import '../charts/bar_chart.dart';
import '../charts/time_series_chart.dart';
import '../design_tokens.dart';
import 'ansi_text.dart';
import 'code_block.dart';
import 'json_tree.dart';

/// What a fence's language draws as, rather than as code.
enum FenceVisual { chart, math, diff, json, ansi }

/// The visual for a fence written in [language] holding [source], or null for
/// plain code. Code that carries escape sequences is drawn as ANSI whatever
/// its fence says.
FenceVisual? fenceVisualFor(String? language, String source) {
  switch (language?.trim().toLowerCase()) {
    case 'chart':
      return FenceVisual.chart;
    case 'math' || 'latex' || 'tex' || 'katex':
      return FenceVisual.math;
    case 'diff' || 'patch':
      return FenceVisual.diff;
    case 'json' || 'jsonc':
      return FenceVisual.json;
    case 'ansi':
      return FenceVisual.ansi;
  }
  return hasAnsi(source) ? FenceVisual.ansi : null;
}

/// A fence drawn as what it describes — a chart, an equation, a diff, a JSON
/// tree, coloured output — with Source and Copy above it. Anything that cannot
/// be drawn shows its source and why.
class VisualFenceBlock extends StatefulWidget {
  const VisualFenceBlock({
    required this.visual,
    required this.source,
    this.language,
    super.key,
  });

  final FenceVisual visual;
  final String source;
  final String? language;

  @override
  State<VisualFenceBlock> createState() => _VisualFenceBlockState();
}

class _VisualFenceBlockState extends State<VisualFenceBlock> {
  bool _source = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final copyText = widget.visual == FenceVisual.ansi
        ? stripAnsi(widget.source)
        : widget.source;
    Widget body;
    if (_source) {
      body = _sourceText(context);
    } else {
      try {
        body = _drawn(context);
      } on Object catch (error) {
        body = _failed(context, '$error');
      }
    }
    return DecoratedBox(
      key: ValueKey('fence-${widget.visual.name}'),
      decoration: BoxDecoration(
        color: theme.brightness == Brightness.dark
            ? scheme.surfaceContainerLowest
            : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SelectionContainer.disabled(
            child: Padding(
              padding: const EdgeInsets.only(left: Insets.sm),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.language ?? widget.visual.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: muted,
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('fence-source'),
                    onPressed: () => setState(() => _source = !_source),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      textStyle: theme.textTheme.labelSmall,
                    ),
                    child: Text(_source ? 'Visual' : 'Source'),
                  ),
                  CopyTextButton(text: copyText, tooltip: 'Copy source'),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Insets.sm,
              0,
              Insets.sm,
              Insets.sm,
            ),
            child: body,
          ),
        ],
      ),
    );
  }

  Widget _sourceText(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Text(
      widget.visual == FenceVisual.ansi
          ? stripAnsi(widget.source)
          : widget.source,
      style: MonoStyles.label.copyWith(
        color: Theme.of(context).colorScheme.onSurface,
      ),
    ),
  );

  Widget _failed(BuildContext context, String reason) {
    final failure = SemanticColors.of(context).failure;
    return Column(
      key: const ValueKey('fence-failed'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(
              AppIcons.warningCircle,
              size: Chrome.iconSmall,
              color: failure,
            ),
            const SizedBox(width: Insets.xs),
            Expanded(
              child: Text(
                "Couldn't draw this: $reason",
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: failure),
              ),
            ),
          ],
        ),
        const SizedBox(height: Insets.xs),
        _sourceText(context),
      ],
    );
  }

  Widget _drawn(BuildContext context) => switch (widget.visual) {
    FenceVisual.json => JsonTreeView(jsonDecode(widget.source), openDepth: 2),
    FenceVisual.ansi => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: AnsiText(widget.source, softWrap: false),
    ),
    FenceVisual.diff => DiffText(widget.source),
    FenceVisual.math => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Math.tex(
        widget.source.trim(),
        mathStyle: MathStyle.display,
        textStyle: TextStyle(color: Theme.of(context).colorScheme.onSurface),
        onErrorFallback: (error) => _failed(context, error.message),
      ),
    ),
    FenceVisual.chart => ChartFence(spec: parseChartSpec(widget.source)),
  };
}

/// A unified diff, each line tinted by what it does.
class DiffText extends StatelessWidget {
  const DiffText(this.source, {super.key});

  final String source;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final semantic = SemanticColors.of(context);
    final mono = MonoStyles.label.copyWith(color: scheme.onSurface);
    TextStyle styleOf(String line) {
      if (line.startsWith('+++') || line.startsWith('---')) {
        return mono.copyWith(fontWeight: FontWeight.w700);
      }
      if (line.startsWith('@@')) {
        return mono.copyWith(color: scheme.tertiary);
      }
      if (line.startsWith('+')) {
        return mono.copyWith(
          color: semantic.diffAdded,
          backgroundColor: semantic.diffAdded.withValues(
            alpha: SemanticColors.surfaceEdgeAlpha,
          ),
        );
      }
      if (line.startsWith('-')) {
        return mono.copyWith(
          color: semantic.diffRemoved,
          backgroundColor: semantic.diffRemoved.withValues(
            alpha: SemanticColors.surfaceEdgeAlpha,
          ),
        );
      }
      return mono.copyWith(color: scheme.onSurfaceVariant);
    }

    final lines = source.split('\n');
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Text.rich(
        TextSpan(
          children: [
            for (var i = 0; i < lines.length; i++)
              TextSpan(
                text: i == lines.length - 1 ? lines[i] : '${lines[i]}\n',
                style: styleOf(lines[i]),
              ),
          ],
        ),
        softWrap: false,
      ),
    );
  }
}

/// A `chart` fence's spec: `{"type": "bar" | "line", "title": "…", "unit":
/// "…", "data": [...]}`. A bar's datum is `{"label", "value"}`; a line's is
/// `{"x": "<ISO date or time>", "y": <number>}`.
class ChartSpec {
  const ChartSpec({
    required this.type,
    required this.bars,
    required this.points,
    this.title,
    this.unit,
  });

  final String type;
  final String? title;
  final String? unit;
  final List<BarDatum> bars;
  final List<TimeSeriesPoint> points;
}

/// [source] as a [ChartSpec]; throws a [FormatException] saying what is wrong.
ChartSpec parseChartSpec(String source) {
  final Object? json = jsonDecode(source);
  if (json is! Map<String, Object?>) {
    throw const FormatException('a chart is a JSON object');
  }
  final type = json['type'];
  final data = json['data'];
  if (type != 'bar' && type != 'line') {
    throw const FormatException('"type" must be "bar" or "line"');
  }
  if (data is! List<Object?> || data.isEmpty) {
    throw const FormatException('"data" must be a non-empty list');
  }
  double number(Object? value, String field) => switch (value) {
    final num n => n.toDouble(),
    _ => throw FormatException('"$field" must be a number'),
  };
  final bars = <BarDatum>[];
  final points = <TimeSeriesPoint>[];
  for (final datum in data) {
    if (datum is! Map<String, Object?>) {
      throw const FormatException('each datum is an object');
    }
    if (type == 'bar') {
      bars.add(
        BarDatum(
          label: '${datum['label'] ?? ''}',
          value: number(datum['value'], 'value'),
        ),
      );
    } else {
      final at = DateTime.tryParse('${datum['x']}');
      if (at == null) {
        throw const FormatException('"x" must be an ISO date or time');
      }
      points.add(TimeSeriesPoint(at, number(datum['y'], 'y')));
    }
  }
  points.sort((a, b) => a.at.compareTo(b.at));
  return ChartSpec(
    type: type! as String,
    title: json['title'] as String?,
    unit: json['unit'] as String?,
    bars: bars,
    points: points,
  );
}

/// A [ChartSpec] drawn with the app's own charts.
class ChartFence extends StatelessWidget {
  const ChartFence({required this.spec, super.key});

  final ChartSpec spec;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    final unit = spec.unit == null ? '' : ' ${spec.unit}';
    String value(double v) =>
        '${v == v.roundToDouble() ? v.round() : v.toStringAsFixed(2)}$unit';
    final title = spec.title;
    final chart = spec.type == 'bar'
        ? BarChart(
            bars: [
              for (final b in spec.bars)
                BarDatum(
                  label: b.label,
                  value: b.value,
                  valueLabel: value(b.value),
                ),
            ],
            color: color,
            semanticsLabel: title ?? 'Bar chart',
            height: 160,
          )
        : _line(spec, color, value, title);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.only(bottom: Insets.xs),
            child: Text(title, style: theme.textTheme.titleSmall),
          ),
        chart,
      ],
    );
  }

  static Widget _line(
    ChartSpec spec,
    Color color,
    String Function(double) value,
    String? title,
  ) {
    final ys = spec.points.map((p) => p.value);
    final lo = ys.reduce((a, b) => a < b ? a : b);
    final hi = ys.reduce((a, b) => a > b ? a : b);
    final pad = hi == lo ? 1.0 : (hi - lo) * 0.1;
    final start = spec.points.first.at;
    final end = spec.points.length == 1
        ? start.add(const Duration(days: 1))
        : spec.points.last.at;
    final dated = end.difference(start) >= const Duration(days: 2);
    return TimeSeriesChart(
      points: spec.points,
      start: start,
      end: end,
      minY: lo < 0 ? lo - pad : 0,
      maxY: hi + pad,
      color: color,
      semanticsLabel: title ?? 'Line chart',
      valueLabel: value,
      timeLabel: (at) => dated
          ? '${at.month}/${at.day}'
          : '${at.hour.toString().padLeft(2, '0')}:'
                '${at.minute.toString().padLeft(2, '0')}',
    );
  }
}
