import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'design_tokens.dart';

/// A turning ring drawn in [Motion.statusSteps] discrete steps per
/// [Motion.statusPeriod], for every indeterminate spinner in the app.
///
/// Every ring reads one [StatusSpinnerClock], so a hundred of them cost one
/// timer and stay phase-locked; under reduced motion, a disabled [TickerMode]
/// or a hidden [Visibility] scope it is a still ring that subscribes to
/// nothing and asks for no frame at all.
class SteppedRing extends StatelessWidget {
  const SteppedRing({
    required this.size,
    required this.color,
    this.stroke = 2.0,
    this.inset = 1.0,
    super.key,
  });

  final double size;
  final Color color;

  /// The ring's line width.
  final double stroke;

  /// The ring's share of its box — below 1 the ring sits inside the square,
  /// the way a glyph sits inside its em square.
  final double inset;

  @override
  Widget build(BuildContext context) {
    // `Visibility.of` as well as `TickerMode`: an `IndexedStack` maintains its
    // hidden children's animations, so a spinner on a surface nobody can see
    // would otherwise keep asking for frames.
    final animate =
        Motion.of(context).animate &&
        TickerMode.valuesOf(context).enabled &&
        Visibility.of(context);
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: SteppedRingPainter(
            color: color,
            stroke: stroke,
            inset: inset,
            clock: animate ? StatusSpinnerClock.instance : null,
          ),
        ),
      ),
    );
  }
}

/// The one clock every [SteppedRing] steps to. A [Timer] rather than a
/// [Ticker]: it asks for a frame [Motion.statusSteps] times a second, never
/// every vsync, and runs only while at least one ring is painting.
class StatusSpinnerClock extends ChangeNotifier {
  StatusSpinnerClock._();

  static final instance = StatusSpinnerClock._();

  int _subscribers = 0;
  Timer? _timer;
  int _step = 0;

  /// Which of the [Motion.statusSteps] positions the ring is at.
  int get step => _step;

  bool get isRunning => _timer != null;

  @visibleForTesting
  int get debugSubscriberCount => _subscribers;

  /// How many times a timer was started, for "one clock, many spinners".
  @visibleForTesting
  int debugTimerStarts = 0;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _subscribers++;
    if (_timer == null) {
      debugTimerStarts++;
      _timer = Timer.periodic(
        Motion.statusPeriod ~/ Motion.statusSteps,
        (_) => _tick(),
      );
    }
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (--_subscribers > 0) return;
    // Stopped once the frame's work is done, not on the spot: a ring whose
    // painter changes (a theme mid-animation lerps its colour) leaves the
    // clock and joins it again in one step, and that must not restart it.
    scheduleMicrotask(() {
      if (_subscribers > 0) return;
      _timer?.cancel();
      _timer = null;
    });
  }

  void _tick() {
    _step = (_step + 1) % Motion.statusSteps;
    notifyListeners();
  }
}

/// Paints a [SteppedRing]. Public so a test can paint it at sizes a layout
/// would never hand it.
class SteppedRingPainter extends CustomPainter {
  SteppedRingPainter({
    required this.color,
    required this.clock,
    this.stroke = 2.0,
    this.inset = 1.0,
  }) : super(repaint: clock);

  final Color color;
  final StatusSpinnerClock? clock;
  final double stroke;
  final double inset;

  @override
  void paint(Canvas canvas, Size size) {
    final diameter = size.shortestSide * inset - stroke;
    if (diameter <= 0) return;
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: diameter / 2,
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawOval(rect, paint..color = color.withValues(alpha: 0.3));
    final turn = (clock?.step ?? 0) / Motion.statusSteps;
    canvas.drawArc(
      rect,
      -math.pi / 2 + turn * 2 * math.pi,
      math.pi / 2,
      false,
      paint..color = color,
    );
  }

  @override
  bool shouldRepaint(SteppedRingPainter old) =>
      old.color != color ||
      old.clock != clock ||
      old.stroke != stroke ||
      old.inset != inset;

  // Equal painters keep their render object's clock subscription: a rebuild
  // must not stop and restart the shared timer.
  @override
  bool operator ==(Object other) =>
      other is SteppedRingPainter &&
      other.color == color &&
      other.clock == clock &&
      other.stroke == stroke &&
      other.inset == inset;

  @override
  int get hashCode => Object.hash(color, clock, stroke, inset);
}
