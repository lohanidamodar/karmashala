import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'chart_support.dart';

/// A word-sized trend: a line through [values], left to right, with the last
/// one dotted. No axes and no interaction — a sparkline sits beside a number
/// that already says what it is.
///
/// [secondaryValues] is a part of each reading — thinking inside output, say —
/// drawn as a filled area under the line on the same scale, so the band's
/// height against the line's is the share. It is read in step with [values]
/// and never drawn above them.
class Sparkline extends StatelessWidget {
  const Sparkline({
    required this.values,
    required this.color,
    required this.semanticsLabel,
    this.secondaryValues,
    this.secondaryColor,
    this.minValue = 0,
    this.maxValue,
    this.height = 20,
    this.width,
    this.area = true,
    super.key,
  });

  final List<double> values;
  final Color color;

  /// A part of each of [values], or null for a single series.
  final List<double>? secondaryValues;

  /// The band's colour; [color] when null.
  final Color? secondaryColor;
  final double minValue;

  /// The top of the scale; the largest value when null.
  final double? maxValue;
  final double height;

  /// Fills the incoming width when null, or 80 where that is unbounded.
  final double? width;
  final bool area;
  final String semanticsLabel;

  static const double _fallbackWidth = 80;

  @override
  Widget build(BuildContext context) {
    final ink = ChartInk.of(context);
    return Semantics(
      container: true,
      label: semanticsLabel,
      child: ExcludeSemantics(
        // No LayoutBuilder: a menu or popover measures its content's
        // intrinsic size, which a LayoutBuilder refuses — the card it sat in
        // failed layout and closed as it opened. LimitedBox gives the same
        // rule: the incoming width, or the fallback where that is unbounded.
        child: LimitedBox(
          maxWidth: _fallbackWidth,
          child: SizedBox(
            width: width ?? double.infinity,
            height: height,
            child: CustomPaint(
              painter: SparklinePainter(
                values: values,
                color: color,
                secondaryValues: secondaryValues,
                secondaryColor: secondaryColor,
                minValue: minValue,
                maxValue: maxValue,
                areaAlpha: area ? ink.areaAlpha : 0,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints a [Sparkline].
class SparklinePainter extends CustomPainter {
  const SparklinePainter({
    required this.values,
    required this.color,
    this.secondaryValues,
    this.secondaryColor,
    this.minValue = 0,
    this.maxValue,
    this.areaAlpha = 0,
  });

  final List<double> values;
  final Color color;
  final List<double>? secondaryValues;
  final Color? secondaryColor;
  final double minValue;
  final double? maxValue;
  final double areaAlpha;

  static const double _stroke = 1.5;
  static const double _dot = 2;

  /// How solid the band is drawn: a part of the line's own reading, so it is
  /// darker than the line's wash and lighter than the line. Public so a legend
  /// swatch can match it.
  static const double bandAlpha = 0.55;

  @override
  void paint(Canvas canvas, Size size) {
    final finite = [
      for (final v in values)
        if (v.isFinite) v,
    ];
    if (finite.isEmpty || size.width <= 0 || size.height <= 0) return;
    final top = maxValue ?? finite.reduce(math.max);
    final span = top - minValue;
    final inset = _dot;
    final plotHeight = math.max(0.0, size.height - inset * 2);
    final plotWidth = math.max(0.0, size.width - inset * 2);

    double x(int i) => finite.length == 1
        ? size.width - inset
        : inset + plotWidth * i / (finite.length - 1);

    double y(double value) {
      final fraction = span <= 0
          ? 0.0
          : ((value - minValue) / span).clamp(0.0, 1.0);
      return inset + plotHeight * (1 - fraction);
    }

    Offset at(int i) => Offset(x(i), y(finite[i]));

    final line = Path();
    for (var i = 0; i < finite.length; i++) {
      final p = at(i);
      i == 0 ? line.moveTo(p.dx, p.dy) : line.lineTo(p.dx, p.dy);
    }

    if (finite.length > 1 && areaAlpha > 0) {
      final fill = Path.from(line)
        ..lineTo(at(finite.length - 1).dx, size.height)
        ..lineTo(at(0).dx, size.height)
        ..close();
      canvas.drawPath(
        fill,
        Paint()..color = color.withValues(alpha: areaAlpha),
      );
    }
    _paintBand(canvas, size, finite, x, y);
    if (finite.length > 1) {
      canvas.drawPath(
        line,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = _stroke
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round,
      );
    }
    canvas.drawCircle(at(finite.length - 1), _dot, Paint()..color = color);
  }

  /// The secondary series as an area from the baseline. Read by index against
  /// the finite primary readings and capped at each, so a band is never taller
  /// than the line it is a part of; a reading it lacks, or one that is not a
  /// number, is drawn as nothing.
  void _paintBand(
    Canvas canvas,
    Size size,
    List<double> finite,
    double Function(int) x,
    double Function(double) y,
  ) {
    final band = secondaryValues;
    if (band == null || finite.length < 2) return;
    final path = Path()..moveTo(x(0), size.height);
    for (var i = 0; i < finite.length; i++) {
      final raw = i < band.length ? band[i] : 0.0;
      final value = raw.isFinite ? math.min(raw, finite[i]) : 0.0;
      path.lineTo(x(i), y(math.max(value, minValue)));
    }
    path
      ..lineTo(x(finite.length - 1), size.height)
      ..close();
    canvas.drawPath(
      path,
      Paint()..color = (secondaryColor ?? color).withValues(alpha: bandAlpha),
    );
  }

  @override
  bool shouldRepaint(SparklinePainter oldDelegate) =>
      !_sameValues(oldDelegate.values, values) ||
      !_sameOptionalValues(oldDelegate.secondaryValues, secondaryValues) ||
      oldDelegate.color != color ||
      oldDelegate.secondaryColor != secondaryColor ||
      oldDelegate.minValue != minValue ||
      oldDelegate.maxValue != maxValue ||
      oldDelegate.areaAlpha != areaAlpha;
}

bool _sameOptionalValues(List<double>? a, List<double>? b) {
  if (a == null || b == null) return a == b;
  return _sameValues(a, b);
}

bool _sameValues(List<double> a, List<double> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
