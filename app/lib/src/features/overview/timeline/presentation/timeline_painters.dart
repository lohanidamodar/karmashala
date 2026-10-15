import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
    this.surface = Colors.transparent,
    this.selected = Colors.transparent,
    this.title = const TextStyle(),
    this.subtitle = const TextStyle(),
    this.waitLabel = const TextStyle(),
    this.axisLabel = const TextStyle(),
    this.axisDay = const TextStyle(),
    this.nowLabel = const TextStyle(),
  });

  factory TimelinePalette.of(BuildContext context) {
    final semantic = SemanticColors.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final axis = ChartInk.of(context).axisLabel;
    final small = theme.textTheme.labelSmall ?? const TextStyle();
    return TimelinePalette(
      working: semantic.working,
      waiting: semantic.attention,
      ready: semantic.idle,
      paused: semantic.neutral,
      ink: scheme.onSurface,
      faint: scheme.outlineVariant,
      now: scheme.primary,
      surface: scheme.surface,
      selected: StateLayers.selected(scheme),
      title: (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w500,
      ),
      subtitle: small.copyWith(
        color: scheme.onSurfaceVariant,
        fontWeight: FontWeight.w400,
        letterSpacing: 0,
      ),
      waitLabel: small.copyWith(
        color: semantic.attention,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      axisLabel: axis,
      axisDay: axis.copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w600,
      ),
      nowLabel: axis.copyWith(
        color: scheme.onPrimary,
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

  /// The ground under the lanes, and a chosen row's wash over it.
  final Color surface;
  final Color selected;

  /// A session's name on its bar, the facts after it, and how long it kept
  /// the owner waiting.
  final TextStyle title;
  final TextStyle subtitle;
  final TextStyle waitLabel;

  /// An hour on the axis, a day's first, and the time in the now pill.
  final TextStyle axisLabel;
  final TextStyle axisDay;
  final TextStyle nowLabel;

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
      other.surface == surface &&
      other.selected == selected &&
      other.title == title &&
      other.subtitle == subtitle &&
      other.waitLabel == waitLabel &&
      other.axisLabel == axisLabel &&
      other.axisDay == axisDay &&
      other.nowLabel == nowLabel;

  @override
  int get hashCode => Object.hash(
    working,
    waiting,
    ready,
    paused,
    ink,
    faint,
    now,
    surface,
    selected,
    title,
    subtitle,
    waitLabel,
    axisLabel,
    axisDay,
    nowLabel,
  );
}

/// The stretch of time on screen, mapped to a width.
@immutable
class TimelineViewport {
  const TimelineViewport({required this.start, required this.end});

  final DateTime start;
  final DateTime end;

  Duration get span => end.difference(start);

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
  static const stroke = Insets.hair;
  static const strokeBold = Insets.hair * 1.5;

  /// The gap between a hatch's lines and a paused span's dots.
  static const patternGap = Insets.sm - Insets.xxs;

  /// A marker's diamond, and the ring a live bar ends in.
  static const marker = Insets.xs;
  static const liveRing = Insets.xs;
}

/// Draws one span of [state] into [rect]: solid while working, hatched while
/// waiting, dotted while paused, a thin rail while ready — so the state is
/// never told by colour alone. [inferred] marks are lighter and dashed;
/// [dim] fades a mark that is not the point of the view.
void paintTimelineSpan(
  Canvas canvas,
  Rect rect,
  TimelineState state,
  TimelinePalette palette, {
  bool inferred = false,
  bool dim = false,
}) {
  final base = palette.of(state);
  var alpha = state == TimelineState.ready
      ? ChartAlphas.guide
      : ChartAlphas.mark;
  if (inferred) alpha *= ChartAlphas.inferred;
  if (dim) alpha *= ChartAlphas.rest;
  final bar = state == TimelineState.ready
      ? Rect.fromCenter(
          center: rect.center,
          width: rect.width,
          height: math.min(rect.height, Chrome.timelineRail),
        )
      : rect;
  final shape = RRect.fromRectAndRadius(
    bar,
    Radius.circular(math.min(bar.height, bar.width) / 2),
  );
  canvas.drawRRect(shape, Paint()..color = base.withValues(alpha: alpha));
  final pattern = palette.surface.withValues(
    alpha: dim ? ChartAlphas.band : ChartAlphas.pattern,
  );
  switch (state) {
    case TimelineState.waiting:
      canvas.save();
      canvas.clipRRect(shape);
      final paint = Paint()
        ..color = pattern
        ..strokeWidth = _Marks.strokeBold;
      final h = bar.height;
      for (var x = bar.left - h; x < bar.right; x += _Marks.patternGap) {
        canvas.drawLine(Offset(x, bar.bottom), Offset(x + h, bar.top), paint);
      }
      canvas.restore();
    case TimelineState.paused:
      final paint = Paint()..color = pattern;
      for (
        var x = bar.left + _Marks.patternGap / 2;
        x < bar.right;
        x += _Marks.patternGap
      ) {
        canvas.drawCircle(Offset(x, bar.center.dy), _Marks.strokeBold, paint);
      }
    case TimelineState.working || TimelineState.ready:
      break;
  }
  if (inferred && state != TimelineState.ready) {
    final paint = Paint()
      ..color = base.withValues(alpha: ChartAlphas.outline)
      ..strokeWidth = _Marks.stroke;
    for (final y in [bar.top, bar.bottom]) {
      drawDashedLine(canvas, Offset(bar.left, y), Offset(bar.right, y), paint);
    }
  }
}

/// Where a row's parts sit: the lanes run from [laneLeft] to [laneRight];
/// the avatar sits just before the bar's start and the title starts with
/// the bar. Both stick to the left edge once the start is scrolled past.
@immutable
class TimelineRowLayout {
  const TimelineRowLayout._({
    required this.laneLeft,
    required this.laneRight,
    required this.avatar,
    required this.textLeft,
    required this.barTop,
    required this.barHeight,
  });

  factory TimelineRowLayout.of(
    TimelineSession session,
    TimelineViewport viewport, {
    required double width,
    required double height,
  }) {
    final child = session.depth > 0;
    final avatar = child ? Chrome.miniAvatar : Chrome.timelineAvatar;
    final bar = child ? Chrome.timelineSubBar : Chrome.timelineBar;
    const laneLeft = Chrome.timelineGutter;
    final laneRight = math.max(laneLeft + 1, width - Insets.lg);
    final x = laneLeft + viewport.xOf(session.start, laneRight - laneLeft);
    final stuck = x < laneLeft;
    // A start near the right edge keeps room for its title: the title and
    // its avatar step back together rather than overlap.
    final textLeft = stuck
        ? laneLeft
        : math.max(laneLeft, math.min(x, width - titleRoom));
    final avatarLeft = stuck
        ? (laneLeft - avatar) / 2
        : textLeft - Insets.xs - avatar;
    return TimelineRowLayout._(
      laneLeft: laneLeft,
      laneRight: laneRight,
      avatar: Rect.fromLTWH(avatarLeft, (height - avatar) / 2, avatar, avatar),
      textLeft: textLeft,
      barTop: height - Insets.sm - bar,
      barHeight: bar,
    );
  }

  /// The least a title is given before it steps back from the right edge.
  static const titleRoom = Chrome.peekMinWidth / 2;

  final double laneLeft;
  final double laneRight;
  final Rect avatar;
  final double textLeft;
  final double barTop;
  final double barHeight;

  double get barBottom => barTop + barHeight;

  double xOf(TimelineViewport viewport, DateTime at) =>
      laneLeft + viewport.xOf(at, laneRight - laneLeft);

  /// How tall [session]'s row must be for a title line [titleHeight] tall,
  /// never less than its token.
  static double heightFor(TimelineSession session, double titleHeight) {
    final child = session.depth > 0;
    final least = child ? Chrome.timelineSubLane : Chrome.timelineLane;
    final bar = child ? Chrome.timelineSubBar : Chrome.timelineBar;
    return math.max(
      least,
      (Insets.xs + titleHeight + Insets.xs + bar + Insets.sm).ceilToDouble(),
    );
  }
}

String _clock(DateTime at) {
  final local = at.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

/// **One session's lane**: its title riding on its bar, its spans in state
/// marks, turn ticks, markers and the live end. The avatar is a widget over
/// it; everything else is painted, so a lane is one render object.
class TimelineRowPainter extends CustomPainter {
  TimelineRowPainter({
    required this.session,
    required this.viewport,
    required this.palette,
    required this.now,
    this.selected = false,
    this.waitsOnly = false,
    this.folded = 0,
    this.agentName,
    this.textScaler = TextScaler.noScaling,
  });

  final TimelineSession session;
  final TimelineViewport viewport;
  final TimelinePalette palette;
  final DateTime now;
  final bool selected;
  final bool waitsOnly;

  /// How many sub-sessions are folded away under it.
  final int folded;

  /// The agent's name as the app shows it; the log's id when null.
  final String? agentName;
  final TextScaler textScaler;

  TimelineRowLayout _layout(Size size) => TimelineRowLayout.of(
    session,
    viewport,
    width: size.width,
    height: size.height,
  );

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    if (selected) {
      canvas.drawRect(Offset.zero & size, Paint()..color = palette.selected);
    }
    final layout = _layout(size);
    final top = layout.barTop;
    final bottom = layout.barBottom;

    final nowX = layout.xOf(viewport, now);
    if (nowX >= layout.laneLeft && nowX <= layout.laneRight) {
      canvas.drawLine(
        Offset(nowX, 0),
        Offset(nowX, size.height),
        Paint()
          ..color = palette.now.withValues(alpha: ChartAlphas.pattern)
          ..strokeWidth = _Marks.strokeBold,
      );
    }

    if (session.startOnly) {
      final x = layout.xOf(viewport, session.start);
      if (x >= layout.laneLeft && x <= layout.laneRight) {
        canvas.drawCircle(
          Offset(x, (top + bottom) / 2),
          _Marks.liveRing,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = _Marks.strokeBold
            ..color = palette.ready.withValues(alpha: ChartAlphas.guide),
        );
      }
    }

    for (final span in session.spans) {
      if (!viewport.shows(span.from, span.to)) continue;
      final left = math.max(layout.laneLeft, layout.xOf(viewport, span.from));
      final right = math.min(layout.laneRight, layout.xOf(viewport, span.to));
      if (right - left < _Marks.stroke / 2) continue;
      paintTimelineSpan(
        canvas,
        Rect.fromLTRB(
          left,
          top,
          math.max(left + _Marks.strokeBold, right),
          bottom,
        ),
        span.state,
        palette,
        inferred: span.approximate || span.backfilled,
        dim: waitsOnly && span.state != TimelineState.waiting,
      );
    }

    final guide = Paint()
      ..color = palette.ink.withValues(alpha: ChartAlphas.guide)
      ..strokeWidth = _Marks.stroke;
    for (final tick in session.ticks) {
      final x = layout.xOf(viewport, tick);
      if (x < layout.laneLeft || x > layout.laneRight) continue;
      canvas.drawLine(
        Offset(x, top - Insets.xxs),
        Offset(x, top + Insets.xxs),
        guide,
      );
    }

    for (final marker in session.markers) {
      final x = layout.xOf(viewport, marker.at);
      if (x < layout.laneLeft || x > layout.laneRight) continue;
      final c = Offset(x, (top + bottom) / 2);
      const r = _Marks.marker;
      canvas.drawPath(
        Path()
          ..moveTo(c.dx, c.dy - r)
          ..lineTo(c.dx + r, c.dy)
          ..lineTo(c.dx, c.dy + r)
          ..lineTo(c.dx - r, c.dy)
          ..close(),
        Paint()
          ..color = marker.kind == ActivityKind.waitEnded
              ? palette.waiting
              : guide.color,
      );
    }

    if (session.live) {
      final x = layout.xOf(viewport, session.end);
      if (x >= layout.laneLeft && x <= layout.laneRight) {
        final c = Offset(x, (top + bottom) / 2);
        canvas.drawCircle(c, _Marks.liveRing, Paint()..color = palette.surface);
        canvas.drawCircle(
          c,
          _Marks.liveRing,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = _Marks.strokeBold * 1.5
            ..color = palette.of(session.stateNow ?? TimelineState.working),
        );
      }
    }

    _title(canvas, size, layout);
    canvas.restore();
  }

  void _title(Canvas canvas, Size size, TimelineRowLayout layout) {
    final waited = session.waitingTotal;
    // Most telling first, so a narrow lane cuts the least telling.
    final facts = [
      if (session.startOnly)
        'started ${_clock(session.start)}'
      else
        '${_clock(session.start)}–'
            '${session.live ? 'now' : _clock(session.end)}',
      if (session.deleted) 'deleted',
      ?(agentName ?? session.agent),
      ?session.machine,
    ].join(' · ');
    final painter = TextPainter(
      text: TextSpan(
        style: palette.title,
        children: [
          TextSpan(
            text: session.title,
            style: TextStyle(
              fontStyle: session.backfilled ? FontStyle.italic : null,
              decoration: session.deleted ? TextDecoration.lineThrough : null,
            ),
          ),
          if (waited > Duration.zero)
            TextSpan(
              text: '  ? waited ${describeDuration(waited)}',
              style: palette.waitLabel,
            ),
          if (folded > 0)
            TextSpan(text: '  +$folded folded', style: palette.subtitle),
          TextSpan(text: '   $facts', style: palette.subtitle),
        ],
      ),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      maxLines: 1,
      ellipsis: '…',
    );
    final left = layout.textLeft;
    painter.layout(maxWidth: math.max(0, size.width - Insets.sm - left));
    final y = math.max(Insets.xxs, layout.barTop - Insets.xs - painter.height);
    painter.paint(canvas, Offset(left, y));
    painter.dispose();
  }

  @override
  SemanticsBuilderCallback get semanticsBuilder => (size) {
    final layout = _layout(size);
    final out = <CustomPainterSemantics>[];
    for (final span in session.spans) {
      if (!viewport.shows(span.from, span.to)) continue;
      final left = math.max(layout.laneLeft, layout.xOf(viewport, span.from));
      final right = math.min(layout.laneRight, layout.xOf(viewport, span.to));
      if (right - left < 1) continue;
      out.add(
        CustomPainterSemantics(
          rect: Rect.fromLTRB(left, layout.barTop, right, layout.barBottom),
          properties: SemanticsProperties(
            label: '${session.title}: ${describeSpan(span)}',
            textDirection: TextDirection.ltr,
          ),
        ),
      );
    }
    return out;
  };

  @override
  bool shouldRepaint(TimelineRowPainter old) =>
      old.session != session ||
      old.viewport != viewport ||
      old.palette != palette ||
      old.now != now ||
      old.selected != selected ||
      old.waitsOnly != waitsOnly ||
      old.folded != folded ||
      old.agentName != agentName ||
      old.textScaler != textScaler;

  @override
  bool shouldRebuildSemantics(TimelineRowPainter oldDelegate) =>
      oldDelegate.session != session || oldDelegate.viewport != viewport;
}

/// One state's look on its own, for the legend and the detail's spans.
class TimelineSwatchPainter extends CustomPainter {
  TimelineSwatchPainter({
    required this.state,
    required this.palette,
    this.inferred = false,
  });

  final TimelineState state;
  final TimelinePalette palette;
  final bool inferred;

  @override
  void paint(Canvas canvas, Size size) => paintTimelineSpan(
    canvas,
    Offset.zero & size,
    state,
    palette,
    inferred: inferred,
  );

  @override
  bool shouldRepaint(TimelineSwatchPainter old) =>
      old.state != state || old.palette != palette || old.inferred != inferred;
}

/// The hours along the top of the lanes, with now as a pill on them.
class TimelineAxisPainter extends CustomPainter {
  TimelineAxisPainter({
    required this.viewport,
    required this.palette,
    required this.now,
    this.left = 0,
    this.right = 0,
    this.textScaler = TextScaler.noScaling,
  });

  final TimelineViewport viewport;
  final TimelinePalette palette;
  final DateTime now;

  /// The lanes' insets from the band's edges.
  final double left;
  final double right;
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
  static const double _labelInset = Insets.xxs;

  /// The tick under a label.
  static const double _tick = Insets.xs + Insets.xxs;

  /// About one label per this much width.
  static const double _labelEvery = Insets.xxl * 2 + Insets.lg;

  /// How tall the axis band must be for its labels in [style] at
  /// [textScaler]: the label, then room for the tick under it. Never less
  /// than [minimum]. Measured, not assumed: the app's own font is taller
  /// than a test's.
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
    final w = math.max(1.0, size.width - left - right);
    double xOf(DateTime at) => left + viewport.xOf(at, w);
    final step = stepFor(viewport, w);
    final startLocal = viewport.start.toLocal();
    var at = DateTime(startLocal.year, startLocal.month, startLocal.day);
    while (at.add(step).isBefore(startLocal)) {
      at = at.add(step);
    }
    final line = Paint()
      ..color = palette.faint
      ..strokeWidth = _Marks.stroke;
    final nowX = xOf(now);
    final nowShown = nowX >= left && nowX <= left + w;
    final nowLabel = TextPainter(
      text: TextSpan(text: _clock(now), style: palette.nowLabel),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    )..layout();
    final pill = Rect.fromCenter(
      center: Offset(nowX, _labelInset + nowLabel.height / 2),
      width: nowLabel.width + Insets.sm,
      height: nowLabel.height,
    );
    var guard = 0;
    while (at.isBefore(viewport.end.toLocal()) && guard++ < 500) {
      final x = xOf(at.toUtc());
      if (x >= left) {
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
        final label = Rect.fromLTWH(
          x + _labelInset,
          _labelInset,
          painter.width,
          painter.height,
        );
        // The now pill takes the place of a label it would cover.
        if (!nowShown || !label.inflate(Insets.xs).overlaps(pill)) {
          painter.paint(canvas, label.topLeft);
        }
        painter.dispose();
      }
      at = step >= const Duration(days: 1)
          ? DateTime(at.year, at.month, at.day + step.inDays)
          : at.add(step);
    }
    if (nowShown) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(pill, Radius.circular(pill.height / 2)),
        Paint()..color = palette.now,
      );
      nowLabel.paint(canvas, pill.topLeft + const Offset(Insets.xs, 0));
      canvas.drawLine(
        Offset(nowX, pill.bottom),
        Offset(nowX, size.height),
        Paint()
          ..color = palette.now
          ..strokeWidth = _Marks.strokeBold,
      );
    }
    nowLabel.dispose();
  }

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  bool shouldRepaint(TimelineAxisPainter old) =>
      old.viewport != viewport ||
      old.palette != palette ||
      old.now != now ||
      old.left != left ||
      old.right != right ||
      old.textScaler != textScaler;
}

/// One sub-session's stem: down from its parent's bar to the top of its own
/// avatar, in list coordinates.
@immutable
class TimelineStem {
  const TimelineStem({
    required this.x,
    required this.top,
    required this.bottom,
  });

  final double x;
  final double top;
  final double bottom;

  @override
  bool operator ==(Object other) =>
      other is TimelineStem &&
      other.x == x &&
      other.top == top &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(x, top, bottom);
}

/// The family stems over the lanes, drawn as the dashboard's tree draws
/// them. Repaints with the scroll, and draws only those on screen.
class TimelineStemPainter extends CustomPainter {
  TimelineStemPainter({
    required this.stems,
    required this.palette,
    required this.scroll,
    required this.top,
  }) : super(repaint: scroll);

  final List<TimelineStem> stems;
  final TimelinePalette palette;
  final ScrollController scroll;

  /// Where the lanes begin, below the axis.
  final double top;

  @override
  void paint(Canvas canvas, Size size) {
    final offset = scroll.hasClients ? scroll.offset : 0.0;
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, top, size.width, size.height));
    final paint = Paint()
      ..color = palette.ink.withValues(alpha: ChartAlphas.pattern)
      ..strokeWidth = Chrome.treeLine
      ..strokeCap = StrokeCap.round;
    for (final stem in stems) {
      final y1 = top + stem.top - offset;
      final y2 = top + stem.bottom - offset;
      if (y2 < top || y1 > size.height || y2 <= y1) continue;
      if (stem.x < 0 || stem.x > size.width) continue;
      canvas.drawLine(Offset(stem.x, y1), Offset(stem.x, y2), paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(TimelineStemPainter old) =>
      !listEquals(old.stems, stems) || old.palette != palette || old.top != top;
}
