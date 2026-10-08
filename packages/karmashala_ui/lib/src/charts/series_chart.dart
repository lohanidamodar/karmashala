import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:karmashala_core/visuals.dart';

import '../design_tokens.dart';
import 'chart_support.dart';
import 'number_format.dart';

/// The colours a chart's series take, in order: the accent, then the
/// identity hues, which keep clear of the status colours. Past the last it
/// starts again.
abstract final class ChartPalette {
  static const List<ContextHue> _hues = [
    ContextHue.teal,
    ContextHue.magenta,
    ContextHue.olive,
    ContextHue.indigo,
    ContextHue.rose,
    ContextHue.slate,
    ContextHue.violet,
  ];

  /// How many distinct colours there are before they repeat.
  static int get length => _hues.length + 1;

  static Color series(BuildContext context, int index) {
    final theme = Theme.of(context);
    final i = index % length;
    return i == 0
        ? theme.colorScheme.primary
        : _hues[i - 1].of(theme.brightness);
  }
}

/// A number as an axis or a tooltip says it: `812`, `1.5`, `0.25`, `12.4k`.
String formatChartValue(double value) {
  if (!value.isFinite) return '–';
  if (value.abs() >= 10000) return formatCompactCount(value.round());
  if (value == value.roundToDouble()) return value.round().toString();
  final digits = value.abs() >= 100 ? 0 : (value.abs() >= 1 ? 1 : 2);
  var text = value.toStringAsFixed(digits);
  if (text.contains('.')) {
    text = text
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }
  return text;
}

/// A step of 1, 2 or 5 times a power of ten that cuts [span] into about
/// [count] parts.
double niceChartStep(double span, {int count = 5}) {
  if (span <= 0 || !span.isFinite) return 1;
  final raw = span / count;
  final magnitude = math
      .pow(10, (math.log(raw) / math.ln10).floor())
      .toDouble();
  final fraction = raw / magnitude;
  final nice = fraction <= 1
      ? 1
      : fraction <= 2
      ? 2
      : fraction <= 5
      ? 5
      : 10;
  return nice * magnitude;
}

/// A [ChartVisual] drawn: bars grouped per category or lines across an
/// axis, with value ticks, x labels, a legend when there is more than one
/// series, and every value at a point on hover or tap.
class SeriesChart extends StatefulWidget {
  const SeriesChart({required this.chart, this.height = 200, super.key});

  final ChartVisual chart;
  final double height;

  @override
  State<SeriesChart> createState() => _SeriesChartState();
}

class _SeriesChartState extends State<SeriesChart> {
  int? _selected;

  void _select(int? index) {
    if (index != _selected) setState(() => _selected = index);
  }

  @override
  void didUpdateWidget(SeriesChart old) {
    super.didUpdateWidget(old);
    if (old.chart != widget.chart) _selected = null;
  }

  String _value(double v) {
    final unit = widget.chart.unit;
    return unit == null || unit.isEmpty
        ? formatChartValue(v)
        : '${formatChartValue(v)} $unit';
  }

  @override
  Widget build(BuildContext context) {
    final chart = widget.chart;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    if (chart.isEmpty) {
      return SizedBox(
        key: const ValueKey('series-chart-empty'),
        height: Chrome.menuRowTall * 2,
        child: Center(child: Text('No data yet', style: muted)),
      );
    }
    final colors = [
      for (var i = 0; i < chart.series.length; i++)
        ChartPalette.series(context, i),
    ];
    final ink = ChartInk.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final named = chart.series.length > 1;
    final plot = SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final geometry = SeriesChartGeometry(
            size: Size(
              constraints.hasBoundedWidth ? constraints.maxWidth : 320,
              widget.height,
            ),
            chart: chart,
            axisStyle: ink.axisLabel,
            scaler: scaler,
          );
          final selected = _selected != null && _selected! < geometry.xCount
              ? _selected
              : null;
          return MouseRegion(
            onHover: (e) => _select(geometry.indexAt(e.localPosition.dx)),
            onExit: (_) => _select(null),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) {
                final hit = geometry.indexAt(d.localPosition.dx);
                _select(hit == _selected ? null : hit);
              },
              onHorizontalDragUpdate: (d) =>
                  _select(geometry.indexAt(d.localPosition.dx)),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      key: const ValueKey('series-chart-paint'),
                      painter: SeriesChartPainter(
                        geometry: geometry,
                        chart: chart,
                        colors: colors,
                        ink: ink,
                        selected: selected,
                      ),
                    ),
                  ),
                  if (selected != null)
                    Positioned.fill(
                      child: CustomSingleChildLayout(
                        delegate: ChartTooltipLayout(
                          Offset(
                            geometry.xAt(selected),
                            geometry.plot.top + geometry.plot.height / 3,
                          ),
                        ),
                        child: ChartTooltipCard(
                          key: const ValueKey('series-chart-tooltip'),
                          ink: ink,
                          lines: [
                            geometry.xText(selected),
                            for (final (i, s) in chart.series.indexed)
                              if (geometry.valueAt(i, selected) case final v?)
                                s.name.isEmpty
                                    ? _value(v)
                                    : '${s.name}: ${_value(v)}',
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
    final spoken = [
      chart.title ?? '${chart.type.name} chart',
      '${chart.series.length} series, ${chart.pointCount} points',
    ].join(', ');
    return Semantics(
      container: true,
      label: spoken,
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (named)
              Padding(
                padding: const EdgeInsets.only(bottom: Insets.sm),
                child: Wrap(
                  key: const ValueKey('series-chart-legend'),
                  spacing: Insets.md,
                  runSpacing: Insets.xs,
                  children: [
                    for (final (i, s) in chart.series.indexed)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: Chrome.dot,
                            height: Chrome.dot,
                            decoration: BoxDecoration(
                              color: colors[i],
                              borderRadius: BorderRadius.circular(Insets.xxs),
                            ),
                          ),
                          const SizedBox(width: Insets.xs),
                          Flexible(
                            child: Text(
                              s.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: muted,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            if (chart.yLabel case final label?)
              Text(label, style: ink.axisLabel),
            plot,
            if (chart.xLabel case final label?)
              Align(
                alignment: Alignment.centerRight,
                child: Text(label, style: ink.axisLabel),
              ),
          ],
        ),
      ),
    );
  }
}

/// Where everything on a [SeriesChart] goes, shared by painter and hit test.
class SeriesChartGeometry {
  SeriesChartGeometry({
    required this.size,
    required this.chart,
    required TextStyle axisStyle,
    required TextScaler scaler,
  }) {
    _domain();
    final values = [
      for (final s in chart.series)
        for (final p in s.points) ?p.y,
    ];
    var lo = values.isEmpty ? 0.0 : values.reduce(math.min);
    var hi = values.isEmpty ? 1.0 : values.reduce(math.max);
    lo = math.min(lo, 0);
    hi = math.max(hi, 0);
    if (hi == lo) hi = lo + 1;
    final step = niceChartStep(hi - lo);
    minY = (lo / step).floor() * step;
    maxY = (hi / step).ceil() * step;
    yTicks = [for (var t = minY; t <= maxY + step / 2; t += step) t];
    final bare = size.width < _bareWidth || size.height < _bareHeight;
    yLabels = bare
        ? const []
        : [
            for (final t in yTicks)
              layoutChartLabel(formatChartValue(t), axisStyle, scaler),
          ];
    final labelWidth = yLabels.fold<double>(0, (w, l) => math.max(w, l.width));
    final labelHeight = bare
        ? 0.0
        : layoutChartLabel('0', axisStyle, scaler).height;
    final left = bare ? _pad : labelWidth + _gap;
    final top = bare ? _pad : labelHeight / 2 + _pad;
    final bottom = math.max(
      top + 1,
      size.height - (bare ? _pad : labelHeight + _gap),
    );
    var right = math.max(left + 1, size.width - _pad);
    if (chart.axis == ChartAxis.category && chart.type == ChartType.bar) {
      // Few bars on a wide card stay together instead of spreading out.
      final most = left + xCount * _maxSlot;
      right = math.min(right, math.max(left + 1, most));
    }
    plot = Rect.fromLTRB(left, top, right, bottom);
    xLabels = bare ? const [] : _xLabels(axisStyle, scaler);
  }

  /// Under these, a chart drops its axis labels and keeps the marks.
  static const double _bareWidth = 160;
  static const double _bareHeight = 80;
  static const double _pad = 4;
  static const double _gap = 6;
  static const double _maxSlot = 96;
  static const double _maxBar = 40;

  final Size size;
  final ChartVisual chart;
  late final double minY;
  late final double maxY;
  late final List<double> yTicks;
  late final List<TextPainter> yLabels;
  late final Rect plot;

  /// Each x label and the x it is centred on.
  late final List<(double, TextPainter)> xLabels;

  /// The distinct x values, in axis order: what an index means.
  late final List<Object> xs;
  late final Map<Object, int> _xIndex;
  late final double _xMin;
  late final double _xMax;

  int get xCount => xs.length;

  void _domain() {
    final seen = <Object>{};
    final all = <Object>[
      for (final s in chart.series)
        for (final p in s.points)
          if (seen.add(p.x)) p.x,
    ];
    if (chart.axis != ChartAxis.category) {
      all.sort((a, b) => (a as Comparable).compareTo(b));
    }
    xs = all;
    _xIndex = {for (final (i, x) in xs.indexed) x: i};
    double scalar(Object x) => switch (x) {
      final DateTime at => at.microsecondsSinceEpoch.toDouble(),
      final double d => d,
      _ => 0,
    };
    if (chart.axis == ChartAxis.category || xs.isEmpty) {
      _xMin = 0;
      _xMax = 1;
      return;
    }
    var lo = scalar(xs.first);
    var hi = scalar(xs.last);
    if (lo == hi) {
      final pad = chart.axis == ChartAxis.time
          ? const Duration(hours: 12).inMicroseconds.toDouble()
          : (lo.abs() > 0 ? lo.abs() / 2 : 1.0);
      lo -= pad;
      hi += pad;
    }
    _xMin = lo;
    _xMax = hi;
  }

  double get slot => xCount == 0 ? 0 : plot.width / xCount;

  /// The x of the [index]th distinct x value.
  double xAt(int index) {
    if (chart.axis == ChartAxis.category) {
      return plot.left + slot * (index + 0.5);
    }
    final x = xs[index];
    final v = x is DateTime ? x.microsecondsSinceEpoch.toDouble() : x as double;
    const inset = _pad * 2;
    final width = math.max(0.0, plot.width - inset * 2);
    return plot.left + inset + width * (v - _xMin) / (_xMax - _xMin);
  }

  double yFor(double value) {
    final span = maxY - minY;
    if (span <= 0) return plot.bottom;
    return plot.bottom - plot.height * ((value - minY) / span).clamp(0.0, 1.0);
  }

  /// The index under [x]: its slot on a category axis, the nearest value on
  /// a number or time axis.
  int? indexAt(double x) {
    if (xCount == 0) return null;
    if (chart.axis == ChartAxis.category) {
      if (slot <= 0 || x < plot.left || x > plot.right) return null;
      return ((x - plot.left) / slot).floor().clamp(0, xCount - 1);
    }
    var best = 0;
    var distance = double.infinity;
    for (var i = 0; i < xCount; i++) {
      final d = (xAt(i) - x).abs();
      if (d < distance) {
        distance = d;
        best = i;
      }
    }
    return best;
  }

  /// Series [series]'s reading at the [index]th x, if it has one.
  double? valueAt(int series, int index) {
    final x = xs[index];
    for (final p in chart.series[series].points) {
      if (p.x == x) return p.y;
    }
    return null;
  }

  int indexOfX(Object x) => _xIndex[x] ?? 0;

  /// The [index]th x in words.
  String xText(int index) => _xText(xs[index]);

  String _xText(Object x) => switch (x) {
    final DateTime at => _timeText(at),
    final double d => formatChartValue(d),
    _ => '$x',
  };

  bool get _dated {
    if (chart.axis != ChartAxis.time || xs.length < 2) return true;
    final first = xs.first as DateTime;
    final last = xs.last as DateTime;
    return last.difference(first) >= const Duration(days: 2);
  }

  String _timeText(DateTime at) {
    String two(int n) => n.toString().padLeft(2, '0');
    final time = '${two(at.hour)}:${two(at.minute)}';
    final midnight = at.hour == 0 && at.minute == 0 && at.second == 0;
    if (_dated)
      return midnight ? '${at.month}/${at.day}' : '${at.month}/${at.day} $time';
    return time;
  }

  List<(double, TextPainter)> _xLabels(TextStyle style, TextScaler scaler) {
    if (xCount == 0) return const [];
    if (chart.axis == ChartAxis.category) {
      final labels = [
        for (var i = 0; i < xCount; i++)
          layoutChartLabel(xText(i), style, scaler, maxWidth: _maxSlot * 2),
      ];
      final widest = labels.fold<double>(0, (w, l) => math.max(w, l.width));
      final stride = slot <= 0
          ? xCount
          : math.max(
              1,
              ((math.min(widest, _maxSlot * 2) + _gap) / slot).ceil(),
            );
      return [
        for (var i = 0; i < xCount; i += stride)
          (
            xAt(i),
            layoutChartLabel(
              xText(i),
              style,
              scaler,
              maxWidth: math.max(0, slot * stride - _gap),
            ),
          ),
      ];
    }
    // A number or time axis: the first and last value, and evenly between
    // them as many as fit.
    final first = layoutChartLabel(xText(0), style, scaler);
    final room = math.max(
      1,
      (plot.width / (first.width * 2 + _gap * 4)).floor(),
    );
    final count = math.min(xCount, math.min(room, 6));
    final picks = <int>{
      if (count <= 1)
        0
      else
        for (var k = 0; k < count; k++)
          ((xCount - 1) * k / (count - 1)).round(),
    };
    return [
      for (final i in picks)
        (xAt(i), layoutChartLabel(xText(i), style, scaler)),
    ];
  }

  /// How wide each series' bar is in a group, and the group's width.
  (double bar, double group) barWidths() {
    final n = chart.series.length;
    final gap = n > 1 ? Insets.xxs : 0.0;
    final group = math.min(slot * 0.72, n * _maxBar + (n - 1) * gap);
    final bar = math.max(1.0, (group - (n - 1) * gap) / n);
    return (bar, group);
  }
}

/// Paints a [SeriesChart].
class SeriesChartPainter extends CustomPainter {
  SeriesChartPainter({
    required this.geometry,
    required this.chart,
    required this.colors,
    required this.ink,
    this.selected,
  });

  final SeriesChartGeometry geometry;
  final ChartVisual chart;
  final List<Color> colors;
  final ChartInk ink;
  final int? selected;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = geometry.plot;
    if (plot.width <= 1 || plot.height <= 1) return;
    _axes(canvas, size);
    canvas.save();
    canvas.clipRect(plot.inflate(Insets.xxs));
    if (chart.type == ChartType.bar) {
      _bars(canvas);
    } else {
      _lines(canvas);
    }
    canvas.restore();
  }

  void _axes(Canvas canvas, Size size) {
    final plot = geometry.plot;
    final grid = Paint()
      ..color = ink.grid
      ..strokeWidth = 1;
    for (final (i, tick) in geometry.yTicks.indexed) {
      final y = geometry.yFor(tick);
      canvas.drawLine(
        Offset(plot.left, y),
        Offset(plot.right, y),
        tick == 0
            ? (Paint()
                ..color = ink.marker
                ..strokeWidth = 1)
            : grid,
      );
      if (i < geometry.yLabels.length) {
        final label = geometry.yLabels[i];
        label.paint(
          canvas,
          Offset(plot.left - 6 - label.width, y - label.height / 2),
        );
      }
    }
    for (final (x, label) in geometry.xLabels) {
      final left = (x - label.width / 2)
          .clamp(0.0, math.max(0.0, size.width - label.width))
          .toDouble();
      label.paint(canvas, Offset(left, plot.bottom + 4));
      canvas.drawLine(
        Offset(x, plot.bottom),
        Offset(x, plot.bottom + 3),
        Paint()
          ..color = ink.marker.withValues(alpha: ChartAlphas.guide)
          ..strokeWidth = 1,
      );
    }
  }

  void _bars(Canvas canvas) {
    final (bar, group) = geometry.barWidths();
    final gap = chart.series.length > 1 ? Insets.xxs : 0.0;
    final zero = geometry.yFor(0);
    if (selected case final i?) {
      final c = geometry.xAt(i);
      canvas.drawRect(
        Rect.fromLTRB(
          c - geometry.slot / 2,
          geometry.plot.top,
          c + geometry.slot / 2,
          geometry.plot.bottom,
        ),
        Paint()..color = ink.track.withValues(alpha: ChartAlphas.pattern),
      );
    }
    for (final (s, series) in chart.series.indexed) {
      for (final p in series.points) {
        final y = p.y;
        if (y == null) continue;
        final index = geometry.indexOfX(p.x);
        final left = geometry.xAt(index) - group / 2 + s * (bar + gap);
        final top = geometry.yFor(y);
        final rect = Rect.fromLTRB(
          left,
          math.min(top, zero),
          left + bar,
          math.max(top, zero),
        );
        if (rect.height <= 0) continue;
        final dim = selected != null && selected != index;
        final color = colors[s].withValues(
          alpha: dim ? ChartAlphas.inferred : ChartAlphas.mark,
        );
        final corner = Radius.circular(math.min(Insets.xs, bar / 3));
        canvas.drawRRect(
          y >= 0
              ? RRect.fromRectAndCorners(
                  rect,
                  topLeft: corner,
                  topRight: corner,
                )
              : RRect.fromRectAndCorners(
                  rect,
                  bottomLeft: corner,
                  bottomRight: corner,
                ),
          Paint()..color = color,
        );
      }
    }
  }

  void _lines(Canvas canvas) {
    final plot = geometry.plot;
    final single = chart.series.length == 1;
    final dots = geometry.xCount <= 40;
    for (final (s, series) in chart.series.indexed) {
      final color = colors[s];
      final runs = <List<Offset>>[];
      var run = <Offset>[];
      for (final p in series.points) {
        final y = p.y;
        if (y == null) {
          if (run.isNotEmpty) runs.add(run);
          run = <Offset>[];
          continue;
        }
        run.add(Offset(geometry.xAt(geometry.indexOfX(p.x)), geometry.yFor(y)));
      }
      if (run.isNotEmpty) runs.add(run);
      final stroke = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round;
      for (final points in runs) {
        if (points.length == 1) {
          canvas.drawCircle(points.single, 3.5, Paint()..color = color);
          continue;
        }
        final path = Path()..moveTo(points.first.dx, points.first.dy);
        for (final p in points.skip(1)) {
          path.lineTo(p.dx, p.dy);
        }
        if (single) {
          final zero = geometry.yFor(math.max(0, geometry.minY));
          canvas.drawPath(
            Path.from(path)
              ..lineTo(points.last.dx, zero)
              ..lineTo(points.first.dx, zero)
              ..close(),
            Paint()..color = color.withValues(alpha: ink.areaAlpha),
          );
        }
        canvas.drawPath(path, stroke);
        if (dots) {
          for (final p in points) {
            canvas.drawCircle(p, 2.5, Paint()..color = color);
          }
        }
      }
    }
    if (selected case final i?) {
      final x = geometry.xAt(i);
      canvas.drawLine(
        Offset(x, plot.top),
        Offset(x, plot.bottom),
        Paint()
          ..color = ink.marker
          ..strokeWidth = 1,
      );
      for (final (s, _) in chart.series.indexed) {
        final v = geometry.valueAt(s, i);
        if (v == null) continue;
        final dot = Offset(x, geometry.yFor(v));
        canvas.drawCircle(dot, 5, Paint()..color = ink.tooltipBackground);
        canvas.drawCircle(dot, 3.5, Paint()..color = colors[s]);
      }
    }
  }

  @override
  bool shouldRepaint(SeriesChartPainter old) =>
      old.chart != chart ||
      old.selected != selected ||
      old.ink != ink ||
      old.geometry.size != geometry.size ||
      !_sameColors(old.colors, colors);

  static bool _sameColors(List<Color> a, List<Color> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
