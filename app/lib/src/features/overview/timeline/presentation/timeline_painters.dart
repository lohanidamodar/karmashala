import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show ActivityKind;
import 'package:karmashala_ui/tokens.dart';

import '../domain/timeline_model.dart';

/// The app's semantic colours, as the timeline's states read them.
@immutable
class TimelinePalette {
  const TimelinePalette({
    required this.working,
    required this.waiting,
    required this.ready,
    required this.paused,
    required this.ink,
    required this.faint,
    required this.now,
  });

  factory TimelinePalette.of(BuildContext context) {
    final semantic = SemanticColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    return TimelinePalette(
      working: semantic.working,
      waiting: semantic.attention,
      ready: semantic.idle,
      paused: semantic.neutral,
      ink: scheme.onSurface,
      faint: scheme.outlineVariant,
      now: scheme.primary,
    );
  }

  final Color working;
  final Color waiting;
  final Color ready;
  final Color paused;
  final Color ink;
  final Color faint;
  final Color now;

  Color of(TimelineState state) => switch (state) {
    TimelineState.working => working,
    TimelineState.waiting => waiting,
    TimelineState.ready => ready,
    TimelineState.paused => paused,
  };

  @override
  bool operator ==(Object other) =>
      other is TimelinePalette &&
      other.working == working &&
      other.waiting == waiting &&
      other.ready == ready &&
      other.paused == paused &&
      other.ink == ink &&
      other.faint == faint &&
      other.now == now;

  @override
  int get hashCode =>
      Object.hash(working, waiting, ready, paused, ink, faint, now);
}

/// The stretch of time on screen, mapped to a width.
@immutable
class TimelineViewport {
  const TimelineViewport({required this.start, required this.end});

  final DateTime start;
  final DateTime end;

  int get _span => math.max(1, end.difference(start).inMicroseconds);

  double xOf(DateTime at, double width) =>
      at.difference(start).inMicroseconds / _span * width;

  DateTime timeAt(double x, double width) =>
      start.add(Duration(microseconds: (x / width * _span).round()));

  bool shows(DateTime from, DateTime to) =>
      to.isAfter(start) && from.isBefore(end);

  @override
  bool operator ==(Object other) =>
      other is TimelineViewport && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

/// One session's bar: its spans in state colours, waits hatched and pauses
/// dotted so colour is never the only cue, turn ticks along the top, and
/// what was inferred drawn lighter.
class TimelineLanePainter extends CustomPainter {
  TimelineLanePainter({
    required this.session,
    required this.viewport,
    required this.palette,
    required this.now,
    this.compact = false,
    this.labels = true,
    this.textScaler = TextScaler.noScaling,
  });

  final TimelineSession session;
  final TimelineViewport viewport;
  final TimelinePalette palette;
  final DateTime now;
  final bool compact;
  final bool labels;
  final TextScaler textScaler;

  static const double _inferredAlpha = 0.45;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final pad = compact ? 1.0 : 6.0;
    final top = pad;
    final bottom = size.height - pad;
    canvas.save();
    canvas.clipRect(Offset.zero & size);

    final startX = viewport.xOf(session.start, w);
    if (session.startOnly) {
      if (startX >= -4 && startX <= w + 4) {
        final center = Offset(startX, size.height / 2);
        canvas.drawCircle(
          center,
          compact ? 3 : 4.5,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = palette.ready.withValues(alpha: _inferredAlpha + 0.2),
        );
      }
      canvas.restore();
      return;
    }

    if (viewport.shows(session.start, session.end)) {
      final left = math.max(0.0, startX);
      final right = math.min(w, viewport.xOf(session.end, w));
      canvas.drawRect(
        Rect.fromLTRB(left, size.height / 2 - 1, right, size.height / 2 + 1),
        Paint()..color = palette.faint,
      );
    }

    for (final span in session.spans) {
      if (!viewport.shows(span.from, span.to)) continue;
      final left = math.max(0.0, viewport.xOf(span.from, w));
      final right = math.min(w, viewport.xOf(span.to, w));
      if (right - left < 0.5) continue;
      final inferred = span.approximate || span.backfilled;
      final rect = Rect.fromLTRB(left, top, math.max(left + 1, right), bottom);
      final base = palette.of(span.state);
      final alpha = switch (span.state) {
        TimelineState.ready => 0.28,
        _ => 0.9,
      };
      canvas.drawRect(
        rect,
        Paint()
          ..color = base.withValues(
            alpha: inferred ? alpha * _inferredAlpha : alpha,
          ),
      );
      switch (span.state) {
        case TimelineState.waiting:
          _hatch(canvas, rect, palette.ink.withValues(alpha: 0.35));
        case TimelineState.paused:
          _dots(canvas, rect, palette.ink.withValues(alpha: 0.4));
        case TimelineState.working || TimelineState.ready:
          break;
      }
      if (inferred) {
        _dashedOutline(canvas, rect, base.withValues(alpha: 0.8));
      }
      if (labels && !compact && rect.width >= 72) {
        _label(canvas, rect, describeSpan(span).split(' (').first);
      }
    }

    final tickPaint = Paint()
      ..color = palette.ink.withValues(alpha: 0.55)
      ..strokeWidth = 1;
    for (final tick in session.ticks) {
      final x = viewport.xOf(tick, w);
      if (x < 0 || x > w) continue;
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, compact ? size.height : top + 3),
        tickPaint,
      );
    }

    for (final marker in session.markers) {
      final x = viewport.xOf(marker.at, w);
      if (x < 0 || x > w) continue;
      _diamond(
        canvas,
        Offset(x, size.height / 2),
        compact ? 2.5 : 3.5,
        marker.kind == ActivityKind.waitEnded
            ? palette.waiting
            : palette.ink.withValues(alpha: 0.6),
      );
    }

    if (session.live) {
      final x = viewport.xOf(session.end, w);
      if (x >= 0 && x <= w) {
        final path = Path()
          ..moveTo(x, top)
          ..lineTo(x + 5, size.height / 2)
          ..lineTo(x, bottom)
          ..close();
        canvas.drawPath(path, Paint()..color = palette.now);
      }
    }

    final nowX = viewport.xOf(now, w);
    if (nowX >= 0 && nowX <= w && !compact) {
      canvas.drawLine(
        Offset(nowX, 0),
        Offset(nowX, size.height),
        Paint()
          ..color = palette.now.withValues(alpha: 0.35)
          ..strokeWidth = 1,
      );
    }
    canvas.restore();
  }

  void _hatch(Canvas canvas, Rect rect, Color color) {
    canvas.save();
    canvas.clipRect(rect);
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.2;
    final h = rect.height;
    for (var x = rect.left - h; x < rect.right; x += 6) {
      canvas.drawLine(Offset(x, rect.bottom), Offset(x + h, rect.top), paint);
    }
    canvas.restore();
  }

  void _dots(Canvas canvas, Rect rect, Color color) {
    final paint = Paint()..color = color;
    for (var x = rect.left + 3; x < rect.right; x += 6) {
      canvas.drawCircle(Offset(x, rect.center.dy), 1, paint);
    }
  }

  void _dashedOutline(Canvas canvas, Rect rect, Color color) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (final y in [rect.top, rect.bottom]) {
      for (var x = rect.left; x < rect.right; x += 6) {
        canvas.drawLine(
          Offset(x, y),
          Offset(math.min(x + 3, rect.right), y),
          paint,
        );
      }
    }
  }

  void _diamond(Canvas canvas, Offset c, double r, Color color) {
    canvas.drawPath(
      Path()
        ..moveTo(c.dx, c.dy - r)
        ..lineTo(c.dx + r, c.dy)
        ..lineTo(c.dx, c.dy + r)
        ..lineTo(c.dx - r, c.dy)
        ..close(),
      Paint()..color = color,
    );
  }

  void _label(Canvas canvas, Rect rect, String text) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: TypeSizes.micro, color: palette.ink),
      ),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: rect.width - 8);
    if (painter.height > rect.height) return;
    painter.paint(
      canvas,
      Offset(rect.left + 4, rect.center.dy - painter.height / 2),
    );
  }

  @override
  bool shouldRepaint(TimelineLanePainter old) =>
      old.session != session ||
      old.viewport != viewport ||
      old.palette != palette ||
      old.now != now ||
      old.compact != compact ||
      old.textScaler != textScaler;
}

/// The hours along the top of the chart.
class TimelineAxisPainter extends CustomPainter {
  TimelineAxisPainter({
    required this.viewport,
    required this.palette,
    required this.now,
    this.textScaler = TextScaler.noScaling,
  });

  final TimelineViewport viewport;
  final TimelinePalette palette;
  final DateTime now;
  final TextScaler textScaler;

  static const List<Duration> _steps = [
    Duration(minutes: 5),
    Duration(minutes: 15),
    Duration(minutes: 30),
    Duration(hours: 1),
    Duration(hours: 2),
    Duration(hours: 3),
    Duration(hours: 6),
    Duration(hours: 12),
    Duration(days: 1),
    Duration(days: 7),
  ];

  /// How tall the axis band must be for its labels at [textScaler]: the label
  /// from 2 px down, then room for the tick and the "now" dot under it. Never
  /// less than [minimum], so a small scale keeps the band it always had.
  /// Measured, not assumed: the app's own font is taller than a test's.
  static double heightFor(TextScaler textScaler, {double minimum = 24}) {
    final label = TextPainter(
      text: const TextSpan(
        text: 'Mon 30',
        style: TextStyle(
          fontSize: TypeSizes.caption,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    )..layout();
    final height = (2 + label.height + 4 + 6).ceilToDouble();
    label.dispose();
    return math.max(minimum, height);
  }

  /// The step between labels for [viewport] across [width]: about one per
  /// 80 pixels.
  static Duration stepFor(TimelineViewport viewport, double width) {
    final span = viewport.end.difference(viewport.start);
    final wanted = span * (80 / math.max(1, width));
    return _steps.firstWhere((s) => s >= wanted, orElse: () => _steps.last);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final step = stepFor(viewport, w);
    final startLocal = viewport.start.toLocal();
    var at = DateTime(startLocal.year, startLocal.month, startLocal.day);
    while (at.add(step).isBefore(startLocal)) {
      at = at.add(step);
    }
    final line = Paint()
      ..color = palette.faint
      ..strokeWidth = 1;
    var guard = 0;
    while (at.isBefore(viewport.end.toLocal()) && guard++ < 500) {
      final x = viewport.xOf(at.toUtc(), w);
      if (x >= 0) {
        canvas.drawLine(
          Offset(x, size.height - 6),
          Offset(x, size.height),
          line,
        );
        final midnight = at.hour == 0 && at.minute == 0;
        final text = midnight
            ? '${_weekdays[at.weekday - 1]} ${at.day}'
            : '${at.hour.toString().padLeft(2, '0')}:'
                  '${at.minute.toString().padLeft(2, '0')}';
        final painter = TextPainter(
          text: TextSpan(
            text: text,
            style: TextStyle(
              fontSize: TypeSizes.caption,
              color: palette.ink.withValues(alpha: midnight ? 0.9 : 0.65),
              fontWeight: midnight ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
          textDirection: TextDirection.ltr,
          textScaler: textScaler,
        )..layout();
        painter.paint(canvas, Offset(x + 3, 2));
      }
      at = step >= const Duration(days: 1)
          ? DateTime(at.year, at.month, at.day + step.inDays)
          : at.add(step);
    }
    final nowX = viewport.xOf(now, w);
    if (nowX >= 0 && nowX <= w) {
      canvas.drawCircle(
        Offset(nowX, size.height - 3),
        3,
        Paint()..color = palette.now,
      );
    }
  }

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  bool shouldRepaint(TimelineAxisPainter old) =>
      old.viewport != viewport ||
      old.palette != palette ||
      old.now != now ||
      old.textScaler != textScaler;
}

/// Where one arrow runs, in chart coordinates: from the parent's lane at the
/// moment of the link down (or up) to the child's.
@immutable
class TimelineArrowLine {
  const TimelineArrowLine({
    required this.parentY,
    required this.childY,
    required this.at,
  });

  final double parentY;
  final double childY;
  final DateTime at;
}

/// Parent → child arrows over the visible lanes. Repaints with the scroll,
/// and draws only those that cross what is on screen.
class TimelineArrowPainter extends CustomPainter {
  TimelineArrowPainter({
    required this.arrows,
    required this.viewport,
    required this.palette,
    required this.scroll,
    required this.left,
    required this.top,
  }) : super(repaint: scroll);

  final List<TimelineArrowLine> arrows;
  final TimelineViewport viewport;
  final TimelinePalette palette;
  final ScrollController scroll;

  /// Where the bars begin, past the label column.
  final double left;

  /// Where the lanes begin, below the axis.
  final double top;

  @override
  void paint(Canvas canvas, Size size) {
    final offset = scroll.hasClients ? scroll.offset : 0.0;
    final width = size.width - left;
    if (width <= 0) return;
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(left, top, size.width, size.height));
    final paint = Paint()
      ..color = palette.ink.withValues(alpha: 0.55)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    for (final arrow in arrows) {
      final x = left + viewport.xOf(arrow.at, width);
      if (x < left || x > size.width) continue;
      final y1 = top + arrow.parentY - offset;
      final y2 = top + arrow.childY - offset;
      if (math.max(y1, y2) < top || math.min(y1, y2) > size.height) continue;
      canvas.drawLine(Offset(x, y1), Offset(x, y2), paint);
      final dir = y2 >= y1 ? 1.0 : -1.0;
      canvas.drawPath(
        Path()
          ..moveTo(x - 3.5, y2 - 6 * dir)
          ..lineTo(x, y2 - 1 * dir)
          ..lineTo(x + 3.5, y2 - 6 * dir),
        paint,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(TimelineArrowPainter old) =>
      old.arrows != arrows ||
      old.viewport != viewport ||
      old.palette != palette ||
      old.left != left ||
      old.top != top;
}
