import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show ActivityKind;
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/tokens.dart';

import '../domain/timeline_model.dart';

/// The app's semantic colours and type, as the timeline's states read them.
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
    this.spanLabel = const TextStyle(),
    this.axisLabel = const TextStyle(),
    this.axisDay = const TextStyle(),
  });

  factory TimelinePalette.of(BuildContext context) {
    final semantic = SemanticColors.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final axis = ChartInk.of(context).axisLabel;
    return TimelinePalette(
      working: semantic.working,
      waiting: semantic.attention,
      ready: semantic.idle,
      paused: semantic.neutral,
      ink: scheme.onSurface,
      faint: scheme.outlineVariant,
      now: scheme.primary,
      spanLabel: (theme.textTheme.labelSmall ?? const TextStyle()).copyWith(
        color: scheme.onSurface,
        letterSpacing: 0,
      ),
      axisLabel: axis,
      axisDay: axis.copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  final Color working;
  final Color waiting;
  final Color ready;
  final Color paused;
  final Color ink;
  final Color faint;
  final Color now;

  /// A span's words, inside its bar.
  final TextStyle spanLabel;

  /// An hour on the axis, and a day's first.
  final TextStyle axisLabel;
  final TextStyle axisDay;

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
      other.now == now &&
      other.spanLabel == spanLabel &&
      other.axisLabel == axisLabel &&
      other.axisDay == axisDay;

  @override
  int get hashCode => Object.hash(
    working,
    waiting,
    ready,
    paused,
    ink,
    faint,
    now,
    spanLabel,
    axisLabel,
    axisDay,
  );
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

/// The marks' sizes, in the app's spacing.
abstract final class _Marks {
  /// A lane's margin above and below its bar; a compact one's.
  static const pad = Insets.xs + Insets.hair;
  static const padCompact = Insets.hair;

  /// A start-only session's ring, a marker's diamond, the live arrow.
  static const ring = Insets.xs;
  static const ringCompact = Insets.hair * 3;
  static const stroke = Insets.hair;
  static const strokeBold = Insets.hair * 1.5;

  /// The gap between a hatch's lines and a paused span's dots.
  static const patternGap = Insets.sm - Insets.hair * 2;

  /// The least width a span gets its words in.
  static const labelMinWidth = Insets.xxl * 2 + Insets.sm;

  /// A turn's tick down from the top of its lane.
  static const tick = Insets.xs - Insets.hair;
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

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final pad = compact ? _Marks.padCompact : _Marks.pad;
    final top = pad;
    final bottom = size.height - pad;
    canvas.save();
    canvas.clipRect(Offset.zero & size);

    final startX = viewport.xOf(session.start, w);
    if (session.startOnly) {
      if (startX >= -_Marks.ring && startX <= w + _Marks.ring) {
        canvas.drawCircle(
          Offset(startX, size.height / 2),
          compact ? _Marks.ringCompact : _Marks.ring,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = _Marks.strokeBold
            ..color = palette.ready.withValues(alpha: ChartAlphas.guide),
        );
      }
      canvas.restore();
      return;
    }

    if (viewport.shows(session.start, session.end)) {
      final left = math.max(0.0, startX);
      final right = math.min(w, viewport.xOf(session.end, w));
      canvas.drawRect(
        Rect.fromLTRB(
          left,
          size.height / 2 - _Marks.stroke,
          right,
          size.height / 2 + _Marks.stroke,
        ),
        Paint()..color = palette.faint,
      );
    }

    for (final span in session.spans) {
      if (!viewport.shows(span.from, span.to)) continue;
      final left = math.max(0.0, viewport.xOf(span.from, w));
      final right = math.min(w, viewport.xOf(span.to, w));
      if (right - left < _Marks.stroke / 2) continue;
      final inferred = span.approximate || span.backfilled;
      final rect = Rect.fromLTRB(
        left,
        top,
        math.max(left + _Marks.stroke, right),
        bottom,
      );
      final base = palette.of(span.state);
      final alpha = span.state == TimelineState.ready
          ? ChartAlphas.rest
          : ChartAlphas.mark;
      canvas.drawRect(
        rect,
        Paint()
          ..color = base.withValues(
            alpha: inferred ? alpha * ChartAlphas.inferred : alpha,
          ),
      );
      switch (span.state) {
        case TimelineState.waiting:
          _hatch(canvas, rect, palette.ink.withValues(alpha: ChartAlphas.pattern));
        case TimelineState.paused:
          _dots(canvas, rect, palette.ink.withValues(alpha: ChartAlphas.pattern));
        case TimelineState.working || TimelineState.ready:
          break;
      }
      if (inferred) {
        final paint = Paint()
          ..color = base.withValues(alpha: ChartAlphas.outline)
          ..strokeWidth = _Marks.stroke;
        for (final y in [rect.top, rect.bottom]) {
          drawDashedLine(canvas, Offset(rect.left, y), Offset(rect.right, y), paint);
        }
      }
      if (labels && !compact && rect.width >= _Marks.labelMinWidth) {
        _label(canvas, rect, describeSpan(span).split(' (').first);
      }
    }

    final guide = Paint()
      ..color = palette.ink.withValues(alpha: ChartAlphas.guide)
      ..strokeWidth = _Marks.stroke;
    for (final tick in session.ticks) {
      final x = viewport.xOf(tick, w);
      if (x < 0 || x > w) continue;
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, compact ? size.height : top + _Marks.tick),
        guide,
      );
    }

    for (final marker in session.markers) {
      final x = viewport.xOf(marker.at, w);
      if (x < 0 || x > w) continue;
      _diamond(
        canvas,
        Offset(x, size.height / 2),
        compact ? _Marks.ringCompact : _Marks.ring,
        marker.kind == ActivityKind.waitEnded ? palette.waiting : guide.color,
      );
    }

    if (session.live) {
      final x = viewport.xOf(session.end, w);
      if (x >= 0 && x <= w) {
        final path = Path()
          ..moveTo(x, top)
          ..lineTo(x + _Marks.ring, size.height / 2)
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
          ..color = palette.now.withValues(alpha: ChartAlphas.pattern)
          ..strokeWidth = _Marks.stroke,
      );
    }
    canvas.restore();
  }

  void _hatch(Canvas canvas, Rect rect, Color color) {
    canvas.save();
    canvas.clipRect(rect);
    final paint = Paint()
      ..color = color
      ..strokeWidth = _Marks.strokeBold;
    final h = rect.height;
    for (var x = rect.left - h; x < rect.right; x += _Marks.patternGap) {
      canvas.drawLine(Offset(x, rect.bottom), Offset(x + h, rect.top), paint);
    }
    canvas.restore();
  }

  void _dots(Canvas canvas, Rect rect, Color color) {
    final paint = Paint()..color = color;
    for (
      var x = rect.left + _Marks.patternGap / 2;
      x < rect.right;
      x += _Marks.patternGap
    ) {
      canvas.drawCircle(Offset(x, rect.center.dy), _Marks.stroke, paint);
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
      text: TextSpan(text: text, style: palette.spanLabel),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: rect.width - Insets.sm);
    if (painter.height > rect.height) return;
    painter.paint(
      canvas,
      Offset(rect.left + Insets.xs, rect.center.dy - painter.height / 2),
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

  /// A label's inset from its tick and from the top of the band.
  static const double _labelInset = Insets.hair * 2;

  /// The tick under a label, and the now dot's radius.
  static const double _tick = Insets.xs + Insets.hair * 2;
  static const double _nowDot = Insets.hair * 3;

  /// About one label per this much width.
  static const double _labelEvery = Insets.xxl * 2 + Insets.lg;

  /// How tall the axis band must be for its labels in [style] at
  /// [textScaler]: the label, then room for the tick and the now dot under
  /// it. Never less than [minimum]. Measured, not assumed: the app's own font
  /// is taller than a test's.
  static double heightFor(
    TextScaler textScaler, {
    required TextStyle style,
    double minimum = Chrome.paneStrip,
  }) {
    final label = TextPainter(
      text: TextSpan(text: 'Mon 30', style: style),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    )..layout();
    final height = (_labelInset + label.height + Insets.xs + _tick)
        .ceilToDouble();
    label.dispose();
    return math.max(minimum, height);
  }

  /// The step between labels for [viewport] across [width].
  static Duration stepFor(TimelineViewport viewport, double width) {
    final span = viewport.end.difference(viewport.start);
    final wanted = span * (_labelEvery / math.max(1, width));
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
      ..strokeWidth = _Marks.stroke;
    var guard = 0;
    while (at.isBefore(viewport.end.toLocal()) && guard++ < 500) {
      final x = viewport.xOf(at.toUtc(), w);
      if (x >= 0) {
        canvas.drawLine(
          Offset(x, size.height - _tick),
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
            style: midnight ? palette.axisDay : palette.axisLabel,
          ),
          textDirection: TextDirection.ltr,
          textScaler: textScaler,
        )..layout();
        painter.paint(canvas, Offset(x + _labelInset, _labelInset));
      }
      at = step >= const Duration(days: 1)
          ? DateTime(at.year, at.month, at.day + step.inDays)
          : at.add(step);
    }
    final nowX = viewport.xOf(now, w);
    if (nowX >= 0 && nowX <= w) {
      canvas.drawCircle(
        Offset(nowX, size.height - _nowDot),
        _nowDot,
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

  /// The arrowhead's half-width and length.
  static const double _head = Insets.xs;
  static const double _headLength = Insets.sm - Insets.hair * 2;

  @override
  void paint(Canvas canvas, Size size) {
    final offset = scroll.hasClients ? scroll.offset : 0.0;
    final width = size.width - left;
    if (width <= 0) return;
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(left, top, size.width, size.height));
    final paint = Paint()
      ..color = palette.ink.withValues(alpha: ChartAlphas.guide)
      ..strokeWidth = _Marks.strokeBold
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
          ..moveTo(x - _head, y2 - _headLength * dir)
          ..lineTo(x, y2 - _Marks.stroke * dir)
          ..lineTo(x + _head, y2 - _headLength * dir),
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
