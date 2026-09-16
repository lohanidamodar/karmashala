import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:agent_cli/descriptors.dart';

import '../design_tokens.dart';
import 'agent_status_appearance.dart';

/// The glyph for an agent's status: [agentStatusAppearance]'s icon, except
/// that "working" is a stepped spinner rather than a still half-circle.
class StatusGlyph extends StatelessWidget {
  const StatusGlyph({
    required this.status,
    required this.size,
    this.color,
    this.semanticLabel,
    super.key,
  });

  final AgentActivityStatus status;
  final double size;

  /// Null takes the status's own semantic colour.
  final Color? color;

  /// As [Icon.semanticLabel]: null leaves the words to something nearby.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final appearance = agentStatusAppearance(status);
    final colour = color ?? appearance.colour(SemanticColors.of(context));
    if (status == AgentActivityStatus.working) {
      return WorkingSpinner(
        size: size,
        color: colour,
        semanticLabel: semanticLabel,
      );
    }
    return Icon(
      appearance.icon,
      size: size,
      color: colour,
      semanticLabel: semanticLabel,
    );
  }
}

/// A 1.5px ring turning in [Motion.statusSteps] discrete steps per
/// [Motion.statusPeriod]. Every spinner reads one [StatusSpinnerClock], so they
/// stay phase-locked and a hundred of them cost one timer; under reduced motion
/// or a disabled [TickerMode] it is a still ring and subscribes to nothing.
class WorkingSpinner extends StatelessWidget {
  const WorkingSpinner({
    required this.size,
    required this.color,
    this.semanticLabel,
    super.key,
  });

  final double size;
  final Color color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final animate =
        Motion.of(context).animate && TickerMode.valuesOf(context).enabled;
    // Laid out like [Icon], so swapping one for the other moves nothing.
    return Semantics(
      label: semanticLabel,
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: SizedBox.square(
            dimension: size,
            child: CustomPaint(
              painter: _SpinnerPainter(
                color: color,
                clock: animate ? StatusSpinnerClock.instance : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The one clock every [WorkingSpinner] steps to. A [Timer] rather than a
/// [Ticker]: it asks for a frame [Motion.statusSteps] times a second, never
/// every vsync, and runs only while at least one spinner is painting.
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
    if (_subscribers++ == 0) {
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
    if (--_subscribers == 0) {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _tick() {
    _step = (_step + 1) % Motion.statusSteps;
    notifyListeners();
  }
}

class _SpinnerPainter extends CustomPainter {
  _SpinnerPainter({required this.color, required this.clock})
    : super(repaint: clock);

  final Color color;
  final StatusSpinnerClock? clock;

  /// The ring's share of its box — about where a Phosphor circle sits in its
  /// em square, so the spinner reads as the same size as the glyphs beside it.
  static const _inset = 0.8;
  static const _stroke = 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final diameter = size.shortestSide * _inset - _stroke;
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: diameter / 2,
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
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
  bool shouldRepaint(_SpinnerPainter old) =>
      old.color != color || old.clock != clock;

  // Equal painters keep their render object's clock subscription: a rebuild
  // must not stop and restart the shared timer.
  @override
  bool operator ==(Object other) =>
      other is _SpinnerPainter && other.color == color && other.clock == clock;

  @override
  int get hashCode => Object.hash(color, clock);
}
