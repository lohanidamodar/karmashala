import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'chart_support.dart';

/// A word-sized trend: a line through [values], left to right, with the last
/// one dotted. No axes and no interaction — a sparkline sits beside a number
/// that already says what it is.
class Sparkline extends StatelessWidget {
  const Sparkline({
    required this.values,
    required this.color,
    required this.semanticsLabel,
    this.minValue = 0,
    this.maxValue,
    this.height = 20,
    this.width,
    this.area = true,
    super.key,
  });

  final List<double> values;
  final Color color;
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
    this.minValue = 0,
    this.maxValue,
    this.areaAlpha = 0,
  });

  final List<double> values;
  final Color color;
  final double minValue;
  final double? maxValue;
  final double areaAlpha;

  static const double _stroke = 1.5;
  static const double _dot = 2;

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

    Offset at(int i) {
      final x = finite.length == 1
          ? size.width - inset
          : inset + plotWidth * i / (finite.length - 1);
      final fraction = span <= 0
          ? 0.0
          : ((finite[i] - minValue) / span).clamp(0.0, 1.0);
      return Offset(x, inset + plotHeight * (1 - fraction));
    }

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

  @override
  bool shouldRepaint(SparklinePainter oldDelegate) =>
      !_sameValues(oldDelegate.values, values) ||
      oldDelegate.color != color ||
      oldDelegate.minValue != minValue ||
      oldDelegate.maxValue != maxValue ||
      oldDelegate.areaAlpha != areaAlpha;
}

bool _sameValues(List<double> a, List<double> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
