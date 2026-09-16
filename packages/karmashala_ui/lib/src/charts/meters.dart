import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'chart_support.dart';

/// A horizontal gauge: [value] as a filled track, with an optional [marker]
/// tick — where the fill *should* be, such as an even pace through a window.
///
/// [value] and [marker] are fractions; a value over 1 draws full. Colour is the
/// caller's, and never the only signal: [semanticsLabel] must say the number.
class LinearMeter extends StatelessWidget {
  const LinearMeter({
    required this.value,
    required this.color,
    required this.semanticsLabel,
    this.marker,
    this.thickness = 6,
    this.trackColor,
    super.key,
  });

  final double value;
  final Color color;
  final double? marker;
  final double thickness;
  final Color? trackColor;
  final String semanticsLabel;

  /// How far the marker reaches past the track, above and below.
  static const double markerOverhang = 3;

  @override
  Widget build(BuildContext context) {
    final ink = ChartInk.of(context);
    final height = thickness + markerOverhang * 2;
    return Semantics(
      container: true,
      label: semanticsLabel,
      child: ExcludeSemantics(
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: _fraction(value)),
          duration: chartMotion(context),
          curve: Curves.easeOutCubic,
          builder: (context, animated, _) => SizedBox(
            height: height,
            width: double.infinity,
            child: CustomPaint(
              painter: LinearMeterPainter(
                value: animated,
                marker: marker == null ? null : _fraction(marker!),
                color: color,
                track: trackColor ?? ink.track,
                markerColor: ink.marker,
                thickness: thickness,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

double _fraction(double value) =>
    value.isNaN ? 0 : value.clamp(0.0, 1.0).toDouble();

/// Paints a [LinearMeter]. Public so a test can paint it at sizes a layout
/// would never hand it.
class LinearMeterPainter extends CustomPainter {
  const LinearMeterPainter({
    required this.value,
    required this.color,
    required this.track,
    required this.markerColor,
    required this.thickness,
    this.marker,
  });

  final double value;
  final double? marker;
  final Color color;
  final Color track;
  final Color markerColor;
  final double thickness;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final bar = math.min(thickness, size.height);
    final top = (size.height - bar) / 2;
    final radius = Radius.circular(bar / 2);
    final trackRect = Rect.fromLTWH(0, top, size.width, bar);
    canvas.drawRRect(
      RRect.fromRectAndRadius(trackRect, radius),
      Paint()..color = track,
    );
    final filled = size.width * value;
    if (filled > 0) {
      // Never narrower than the bar is tall, so 1% still reads as a mark.
      final width = math.max(filled, math.min(bar, size.width));
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(0, top, width, bar), radius),
        Paint()..color = color,
      );
    }
    final tick = marker;
    if (tick != null) {
      final x = (size.width * tick)
          .clamp(1.0, math.max(1.0, size.width - 1))
          .toDouble();
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = markerColor
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(LinearMeterPainter oldDelegate) =>
      oldDelegate.value != value ||
      oldDelegate.marker != marker ||
      oldDelegate.color != color ||
      oldDelegate.track != track ||
      oldDelegate.markerColor != markerColor ||
      oldDelegate.thickness != thickness;
}

/// A ring gauge: [value] as an arc from twelve o'clock, an optional [marker]
/// tick, and whatever [child] says in the middle.
class RadialMeter extends StatelessWidget {
  const RadialMeter({
    required this.value,
    required this.color,
    required this.semanticsLabel,
    this.marker,
    this.size = 40,
    this.strokeWidth = 4,
    this.trackColor,
    this.child,
    super.key,
  });

  final double value;
  final double? marker;
  final Color color;
  final double size;
  final double strokeWidth;
  final Color? trackColor;
  final String semanticsLabel;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final ink = ChartInk.of(context);
    return Semantics(
      container: true,
      label: semanticsLabel,
      child: ExcludeSemantics(
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: _fraction(value)),
          duration: chartMotion(context),
          curve: Curves.easeOutCubic,
          builder: (context, animated, inner) => CustomPaint(
            painter: RadialMeterPainter(
              value: animated,
              marker: marker == null ? null : _fraction(marker!),
              color: color,
              track: trackColor ?? ink.track,
              markerColor: ink.marker,
              strokeWidth: strokeWidth,
            ),
            child: inner,
          ),
          child: SizedBox.square(
            dimension: size,
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}

/// Paints a [RadialMeter].
class RadialMeterPainter extends CustomPainter {
  const RadialMeterPainter({
    required this.value,
    required this.color,
    required this.track,
    required this.markerColor,
    required this.strokeWidth,
    this.marker,
  });

  final double value;
  final double? marker;
  final Color color;
  final Color track;
  final Color markerColor;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    if (side <= strokeWidth) return;
    final center = size.center(Offset.zero);
    final radius = (side - strokeWidth) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawCircle(center, radius, stroke..color = track);
    if (value > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        2 * math.pi * value,
        false,
        stroke
          ..color = color
          ..strokeCap = StrokeCap.round,
      );
    }
    final tick = marker;
    if (tick != null) {
      final angle = -math.pi / 2 + 2 * math.pi * tick;
      final direction = Offset(math.cos(angle), math.sin(angle));
      canvas.drawLine(
        center + direction * (radius - strokeWidth),
        center + direction * (radius + strokeWidth),
        Paint()
          ..color = markerColor
          ..strokeWidth = 1.5
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(RadialMeterPainter oldDelegate) =>
      oldDelegate.value != value ||
      oldDelegate.marker != marker ||
      oldDelegate.color != color ||
      oldDelegate.track != track ||
      oldDelegate.markerColor != markerColor ||
      oldDelegate.strokeWidth != strokeWidth;
}
