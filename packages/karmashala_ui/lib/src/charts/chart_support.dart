import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// How long a chart may take to move to a new value: [Motion.base], or nothing
/// when the platform asks for reduced motion.
Duration chartMotion(BuildContext context) =>
    (MediaQuery.maybeDisableAnimationsOf(context) ?? false)
    ? Duration.zero
    : Motion.base;

/// Under this width a chart drops its axis labels and keeps only the marks.
const double kChartCompactWidth = 320;

/// The opacities a chart's marks are drawn at, so a painter never invents
/// one: a mark, a resting stretch, a pattern or guide over it, and what is
/// inferred rather than recorded.
abstract final class ChartAlphas {
  /// A solid mark: a span, a bar.
  static const double mark = 0.9;

  /// A stretch at rest beside the marks that matter (idle, ready).
  static const double rest = 0.28;

  /// A pattern or guide drawn over or between marks: hatching, the now line.
  static const double pattern = 0.4;

  /// Ticks, arrows and markers: present, never louder than the marks.
  static const double guide = 0.6;

  /// The outline that says a mark was inferred.
  static const double outline = 0.8;

  /// What an inferred mark keeps of its colour.
  static const double inferred = 0.45;
}

/// The ink every chart shares for its chrome, resolved once per build so a
/// painter never reaches for a colour on its own.
@immutable
class ChartInk {
  const ChartInk({
    required this.grid,
    required this.axisLabel,
    required this.track,
    required this.marker,
    required this.tooltipBackground,
    required this.tooltipBorder,
    required this.tooltipText,
    required this.brightness,
  });

  factory ChartInk.of(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ChartInk(
      grid: scheme.outlineVariant.withValues(alpha: 0.6),
      axisLabel: (theme.textTheme.labelSmall ?? const TextStyle()).copyWith(
        color: scheme.onSurfaceVariant,
        letterSpacing: 0,
        fontWeight: FontWeight.w400,
      ),
      track: scheme.surfaceContainerHighest,
      marker: scheme.onSurfaceVariant.withValues(alpha: 0.7),
      tooltipBackground: scheme.surfaceContainerHigh,
      tooltipBorder: scheme.outlineVariant,
      tooltipText: theme.textTheme.bodySmall ?? const TextStyle(),
      brightness: theme.brightness,
    );
  }

  final Color grid;
  final TextStyle axisLabel;
  final Color track;
  final Color marker;
  final Color tooltipBackground;
  final Color tooltipBorder;
  final TextStyle tooltipText;
  final Brightness brightness;

  /// The wash under a line: stronger on dark, where a light tint disappears.
  double get areaAlpha => brightness == Brightness.dark ? 0.22 : 0.14;

  @override
  bool operator ==(Object other) =>
      other is ChartInk &&
      other.grid == grid &&
      other.axisLabel == axisLabel &&
      other.track == track &&
      other.marker == marker &&
      other.tooltipBackground == tooltipBackground &&
      other.tooltipBorder == tooltipBorder &&
      other.tooltipText == tooltipText &&
      other.brightness == brightness;

  @override
  int get hashCode => Object.hash(
    grid,
    axisLabel,
    track,
    marker,
    tooltipBackground,
    tooltipBorder,
    tooltipText,
    brightness,
  );
}

/// A dashed segment from [a] to [b]. Flutter has no dash effect.
void drawDashedLine(
  Canvas canvas,
  Offset a,
  Offset b,
  Paint paint, {
  double dash = 3,
  double gap = 3,
}) {
  final length = (b - a).distance;
  if (length <= 0) return;
  final direction = (b - a) / length;
  var travelled = 0.0;
  while (travelled < length) {
    final end = math.min(travelled + dash, length);
    canvas.drawLine(a + direction * travelled, a + direction * end, paint);
    travelled = end + gap;
  }
}

/// A laid-out label for a painter, scaled with the ambient text scale.
TextPainter layoutChartLabel(
  String text,
  TextStyle style,
  TextScaler scaler, {
  double maxWidth = double.infinity,
}) {
  return TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: ui.TextDirection.ltr,
    textScaler: scaler,
    maxLines: 1,
    ellipsis: '…',
  )..layout(maxWidth: maxWidth);
}

/// The small card a hovered or tapped mark explains itself in.
class ChartTooltipCard extends StatelessWidget {
  const ChartTooltipCard({required this.lines, required this.ink, super.key});

  final List<String> lines;
  final ChartInk ink;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: ink.tooltipBackground,
          border: Border.all(color: ink.tooltipBorder),
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.sm,
            vertical: Insets.xs,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < lines.length; i++)
                Text(
                  lines[i],
                  maxLines: 1,
                  softWrap: false,
                  style: i == 0
                      ? ink.tooltipText.copyWith(fontWeight: FontWeight.w600)
                      : ink.tooltipText,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Places a tooltip of unknown size beside [anchor], flipped and clamped so it
/// stays inside the chart.
class ChartTooltipLayout extends SingleChildLayoutDelegate {
  ChartTooltipLayout(this.anchor);

  final Offset anchor;

  static const double _gap = 8;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    var x = anchor.dx + _gap;
    if (x + childSize.width > size.width) {
      x = anchor.dx - _gap - childSize.width;
    }
    var y = anchor.dy - childSize.height - _gap;
    if (y < 0) y = anchor.dy + _gap;
    return Offset(
      x.clamp(0.0, math.max(0.0, size.width - childSize.width)),
      y.clamp(0.0, math.max(0.0, size.height - childSize.height)),
    );
  }

  @override
  bool shouldRelayout(ChartTooltipLayout oldDelegate) =>
      oldDelegate.anchor != anchor;
}
