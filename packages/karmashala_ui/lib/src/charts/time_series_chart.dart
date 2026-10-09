import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'chart_support.dart';

/// One reading on a [TimeSeriesChart].
@immutable
class TimeSeriesPoint {
  const TimeSeriesPoint(this.at, this.value);

  final DateTime at;
  final double value;

  @override
  bool operator ==(Object other) =>
      other is TimeSeriesPoint && other.at == at && other.value == value;

  @override
  int get hashCode => Object.hash(at, value);
}

/// One moment of a [TimeSeriesChart.forecastBand]: the range a projection
/// may fall in at [at], from [low] to [high].
@immutable
class TimeSeriesBandPoint {
  const TimeSeriesBandPoint(this.at, this.low, this.high);

  final DateTime at;
  final double low;
  final double high;

  @override
  bool operator ==(Object other) =>
      other is TimeSeriesBandPoint &&
      other.at == at &&
      other.low == low &&
      other.high == high;

  @override
  int get hashCode => Object.hash(at, low, high);
}

/// A moment worth a vertical rule — a quota reset, say — with an optional
/// word drawn beside it when there is room.
@immutable
class ChartMarker {
  const ChartMarker(this.at, {this.label});

  final DateTime at;
  final String? label;

  @override
  bool operator ==(Object other) =>
      other is ChartMarker && other.at == at && other.label == label;

  @override
  int get hashCode => Object.hash(at, label);
}

/// A line (and by default an area) over time, between [start] and [end].
///
/// Pointer hover and a tap both pick the nearest reading and explain it in a
/// small card. Under [kChartCompactWidth] the axis labels go and only the marks
/// stay. Readings further apart than [breakAfter] are not joined: a gap in the
/// record is drawn as one, rather than as a straight line nobody measured.
class TimeSeriesChart extends StatefulWidget {
  const TimeSeriesChart({
    required this.points,
    required this.start,
    required this.end,
    required this.color,
    required this.semanticsLabel,
    required this.valueLabel,
    required this.timeLabel,
    this.minY = 0,
    this.maxY = 100,
    this.markers = const [],
    this.guides = const [],
    this.breakAfter,
    this.area = true,
    this.height = 160,
    this.forecast = const [],
    this.forecastBand = const [],
    super.key,
  });

  /// The range around [forecast] — the slower and faster paces the readings
  /// allow — shaded faintly in the series colour, with no hover. Empty for
  /// none; at least two points to draw.
  final List<TimeSeriesBandPoint> forecastBand;

  /// Where the line goes if nothing changes — drawn dashed, with no area and
  /// no hover, so a projection never reads as a measurement. Empty for none.
  /// Its first point is usually the last reading, so the two lines meet.
  final List<TimeSeriesPoint> forecast;

  final List<TimeSeriesPoint> points;
  final DateTime start;
  final DateTime end;
  final double minY;
  final double maxY;
  final Color color;
  final List<ChartMarker> markers;

  /// Horizontal dashed rules at these values — a limit, say.
  final List<double> guides;
  final Duration? breakAfter;
  final bool area;
  final double height;
  final String Function(double value) valueLabel;
  final String Function(DateTime at) timeLabel;
  final String semanticsLabel;

  @override
  State<TimeSeriesChart> createState() => _TimeSeriesChartState();
}

class _TimeSeriesChartState extends State<TimeSeriesChart> {
  int? _selected;

  List<TimeSeriesPoint> get _sorted =>
      [...widget.points]..sort((a, b) => a.at.compareTo(b.at));

  @override
  void didUpdateWidget(TimeSeriesChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_selected != null && _selected! >= widget.points.length) {
      _selected = null;
    }
  }

  int? _nearest(
    TimeSeriesGeometry geometry,
    List<TimeSeriesPoint> points,
    double x,
  ) {
    int? best;
    var bestDistance = double.infinity;
    for (var i = 0; i < points.length; i++) {
      final px = geometry.xFor(points[i].at);
      if (px < geometry.plot.left - 0.5 || px > geometry.plot.right + 0.5) {
        continue;
      }
      final distance = (px - x).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = i;
      }
    }
    return best;
  }

  void _select(int? index) {
    if (index != _selected) setState(() => _selected = index);
  }

  @override
  Widget build(BuildContext context) {
    final ink = ChartInk.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final points = _sorted;
    return Semantics(
      container: true,
      label: widget.semanticsLabel,
      child: ExcludeSemantics(
        child: SizedBox(
          height: widget.height,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = Size(
                constraints.hasBoundedWidth ? constraints.maxWidth : 320,
                widget.height,
              );
              final geometry = TimeSeriesGeometry(
                size: size,
                start: widget.start,
                end: widget.end,
                minY: widget.minY,
                maxY: widget.maxY,
                axisStyle: ink.axisLabel,
                scaler: scaler,
                valueLabel: widget.valueLabel,
                timeLabel: widget.timeLabel,
              );
              final selected = _selected;
              final chosen = selected != null && selected < points.length
                  ? points[selected]
                  : null;
              return MouseRegion(
                onHover: (event) =>
                    _select(_nearest(geometry, points, event.localPosition.dx)),
                onExit: (_) => _select(null),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (details) {
                    final hit = _nearest(
                      geometry,
                      points,
                      details.localPosition.dx,
                    );
                    _select(hit == _selected ? null : hit);
                  },
                  onHorizontalDragUpdate: (details) => _select(
                    _nearest(geometry, points, details.localPosition.dx),
                  ),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: CustomPaint(
                          painter: TimeSeriesPainter(
                            geometry: geometry,
                            points: points,
                            markers: widget.markers,
                            guides: widget.guides,
                            breakAfter: widget.breakAfter,
                            color: widget.color,
                            ink: ink,
                            area: widget.area,
                            selected: chosen,
                            forecast: widget.forecast,
                            forecastBand: widget.forecastBand,
                          ),
                        ),
                      ),
                      if (chosen != null)
                        Positioned.fill(
                          child: CustomSingleChildLayout(
                            delegate: ChartTooltipLayout(
                              Offset(
                                geometry.xFor(chosen.at),
                                geometry.yFor(chosen.value),
                              ),
                            ),
                            child: ChartTooltipCard(
                              ink: ink,
                              lines: [
                                widget.valueLabel(chosen.value),
                                widget.timeLabel(chosen.at),
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
        ),
      ),
    );
  }
}

/// Where everything on a [TimeSeriesChart] goes, computed once per size and
/// shared by the painter and the hit test so they cannot disagree.
class TimeSeriesGeometry {
  TimeSeriesGeometry({
    required this.size,
    required this.start,
    required this.end,
    required this.minY,
    required this.maxY,
    required TextStyle axisStyle,
    required TextScaler scaler,
    required String Function(double) valueLabel,
    required String Function(DateTime) timeLabel,
  }) : compact = size.width < kChartCompactWidth {
    if (compact) {
      yLabels = const [];
      xLabels = const [];
      plot = Rect.fromLTRB(
        _pad,
        _pad,
        math.max(_pad, size.width - _pad),
        math.max(_pad, size.height - _pad),
      );
      return;
    }
    final ys = [maxY, (minY + maxY) / 2, minY];
    yLabels = [
      for (final y in ys)
        (y, layoutChartLabel(valueLabel(y), axisStyle, scaler)),
    ];
    final labelWidth = yLabels.fold<double>(
      0,
      (w, label) => math.max(w, label.$2.width),
    );
    final xs = [start, end];
    xLabels = [
      for (final x in xs)
        (x, layoutChartLabel(timeLabel(x), axisStyle, scaler)),
    ];
    final labelHeight = xLabels.fold<double>(
      0,
      (h, label) => math.max(h, label.$2.height),
    );
    final topPad = yLabels.first.$2.height / 2 + _pad;
    plot = Rect.fromLTRB(
      labelWidth + _labelGap,
      topPad,
      math.max(labelWidth + _labelGap, size.width - _pad),
      math.max(topPad, size.height - labelHeight - _labelGap),
    );
  }

  static const double _pad = 4;
  static const double _labelGap = 6;

  final Size size;
  final DateTime start;
  final DateTime end;
  final double minY;
  final double maxY;
  final bool compact;
  late final Rect plot;
  late final List<(double, TextPainter)> yLabels;
  late final List<(DateTime, TextPainter)> xLabels;

  double xFor(DateTime at) {
    final span = end.difference(start).inMicroseconds;
    if (span <= 0) return plot.right;
    final fraction = at.difference(start).inMicroseconds / span;
    return plot.left + plot.width * fraction;
  }

  double yFor(double value) {
    final span = maxY - minY;
    if (span <= 0) return plot.bottom;
    final fraction = ((value - minY) / span).clamp(0.0, 1.0);
    return plot.bottom - plot.height * fraction;
  }
}

/// Paints a [TimeSeriesChart].
class TimeSeriesPainter extends CustomPainter {
  TimeSeriesPainter({
    required this.geometry,
    required this.points,
    required this.color,
    required this.ink,
    this.markers = const [],
    this.guides = const [],
    this.breakAfter,
    this.area = true,
    this.selected,
    this.forecast = const [],
    this.forecastBand = const [],
  });

  /// See [TimeSeriesChart.forecastBand].
  final List<TimeSeriesBandPoint> forecastBand;

  /// See [TimeSeriesChart.forecast].
  final List<TimeSeriesPoint> forecast;

  final TimeSeriesGeometry geometry;
  final List<TimeSeriesPoint> points;
  final List<ChartMarker> markers;
  final List<double> guides;
  final Duration? breakAfter;
  final Color color;
  final ChartInk ink;
  final bool area;
  final TimeSeriesPoint? selected;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = geometry.plot;
    if (plot.width <= 0 || plot.height <= 0) return;
    _paintGrid(canvas);

    canvas.save();
    canvas.clipRect(plot.inflate(2));
    _paintMarkers(canvas);
    for (final y in guides) {
      final dy = geometry.yFor(y);
      drawDashedLine(
        canvas,
        Offset(plot.left, dy),
        Offset(plot.right, dy),
        Paint()
          ..color = ink.marker
          ..strokeWidth = 1,
      );
    }
    _paintSeries(canvas);
    _paintForecastBand(canvas);
    _paintForecast(canvas);
    canvas.restore();

    final chosen = selected;
    if (chosen != null) {
      final x = geometry.xFor(chosen.at);
      canvas.drawLine(
        Offset(x, plot.top),
        Offset(x, plot.bottom),
        Paint()
          ..color = ink.marker
          ..strokeWidth = 1,
      );
      final dot = Offset(x, geometry.yFor(chosen.value));
      canvas.drawCircle(dot, 4, Paint()..color = ink.tooltipBackground);
      canvas.drawCircle(dot, 3, Paint()..color = color);
    }
  }

  void _paintGrid(Canvas canvas) {
    final plot = geometry.plot;
    final grid = Paint()
      ..color = ink.grid
      ..strokeWidth = 1;
    canvas.drawLine(plot.bottomLeft, plot.bottomRight, grid);
    for (final (value, label) in geometry.yLabels) {
      final y = geometry.yFor(value);
      if (value != geometry.minY) {
        canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      }
      label.paint(
        canvas,
        Offset(plot.left - 6 - label.width, y - label.height / 2),
      );
    }
    for (var i = 0; i < geometry.xLabels.length; i++) {
      final (at, label) = geometry.xLabels[i];
      final x = geometry.xFor(at);
      final left = i == 0
          ? plot.left
          : (i == geometry.xLabels.length - 1
                ? plot.right - label.width
                : x - label.width / 2);
      label.paint(canvas, Offset(left, plot.bottom + 4));
    }
  }

  void _paintMarkers(Canvas canvas) {
    final plot = geometry.plot;
    final paint = Paint()
      ..color = ink.marker
      ..strokeWidth = 1;
    for (final marker in markers) {
      if (marker.at.isBefore(geometry.start) ||
          marker.at.isAfter(geometry.end)) {
        continue;
      }
      final x = geometry.xFor(marker.at);
      drawDashedLine(
        canvas,
        Offset(x, plot.top),
        Offset(x, plot.bottom),
        paint,
        dash: 2,
        gap: 3,
      );
      final label = marker.label;
      if (label != null && !geometry.compact) {
        final text = layoutChartLabel(
          label,
          ink.axisLabel,
          TextScaler.noScaling,
          maxWidth: math.max(0, plot.right - x - 4),
        );
        if (text.width > 0) text.paint(canvas, Offset(x + 3, plot.top));
      }
    }
  }

  void _paintSeries(Canvas canvas) {
    if (points.isEmpty) return;
    final plot = geometry.plot;
    final runs = <List<Offset>>[];
    var current = <Offset>[];
    for (var i = 0; i < points.length; i++) {
      final gap = breakAfter;
      if (i > 0 &&
          gap != null &&
          points[i].at.difference(points[i - 1].at) > gap) {
        runs.add(current);
        current = <Offset>[];
      }
      current.add(
        Offset(geometry.xFor(points[i].at), geometry.yFor(points[i].value)),
      );
    }
    runs.add(current);

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.75
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final fill = Paint()..color = color.withValues(alpha: ink.areaAlpha);
    for (final run in runs) {
      if (run.isEmpty) continue;
      if (run.length == 1) {
        canvas.drawCircle(run.single, 2.5, Paint()..color = color);
        continue;
      }
      final line = Path()..moveTo(run.first.dx, run.first.dy);
      for (final p in run.skip(1)) {
        line.lineTo(p.dx, p.dy);
      }
      if (area) {
        final shape = Path.from(line)
          ..lineTo(run.last.dx, plot.bottom)
          ..lineTo(run.first.dx, plot.bottom)
          ..close();
        canvas.drawPath(shape, fill);
      }
      canvas.drawPath(line, stroke);
    }
    canvas.drawCircle(runs.last.last, 2.5, Paint()..color = color);
  }

  /// The band: a faint fill between its high and low edges, wide where the
  /// readings disagree, and never mistaken for the measured area.
  void _paintForecastBand(Canvas canvas) {
    if (forecastBand.length < 2) return;
    final first = forecastBand.first;
    final band = Path()
      ..moveTo(geometry.xFor(first.at), geometry.yFor(first.high));
    for (final p in forecastBand.skip(1)) {
      band.lineTo(geometry.xFor(p.at), geometry.yFor(p.high));
    }
    for (final p in forecastBand.reversed) {
      band.lineTo(geometry.xFor(p.at), geometry.yFor(p.low));
    }
    band.close();
    canvas.drawPath(
      band,
      Paint()..color = color.withValues(alpha: ChartAlphas.band),
    );
  }

  /// The projection, dashed in the series colour: the same ink says it is the
  /// same quantity, the dashes that nobody measured it.
  void _paintForecast(Canvas canvas) {
    if (forecast.length < 2) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    for (var i = 1; i < forecast.length; i++) {
      drawDashedLine(
        canvas,
        Offset(
          geometry.xFor(forecast[i - 1].at),
          geometry.yFor(forecast[i - 1].value),
        ),
        Offset(geometry.xFor(forecast[i].at), geometry.yFor(forecast[i].value)),
        paint,
        dash: 4,
        gap: 3,
      );
    }
  }

  @override
  bool shouldRepaint(TimeSeriesPainter oldDelegate) => true;
}
