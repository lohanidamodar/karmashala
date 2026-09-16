import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design_tokens.dart';
import 'chart_support.dart';

/// One part of a [SegmentedBar] and its [ChartLegend] entry.
@immutable
class BarSegment {
  const BarSegment({
    required this.label,
    required this.value,
    required this.color,
    this.valueLabel,
    this.detail,
  });

  final String label;

  /// Null when the part was not recorded: it gets a legend entry that says so
  /// and no width in the bar.
  final int? value;
  final Color color;

  /// The value in words; the raw number when null.
  final String? valueLabel;

  /// A second, muted fact beside the value, such as its share.
  final String? detail;

  bool get recorded => value != null;

  @override
  bool operator ==(Object other) =>
      other is BarSegment &&
      other.label == label &&
      other.value == value &&
      other.color == color &&
      other.valueLabel == valueLabel &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(label, value, color, valueLabel, detail);
}

/// Where each part of a bar [width] wide starts and how wide it is, with
/// [gap] between parts. A non-zero part is never narrower than [minWidth], so
/// a 0.1% sliver still shows; the room it takes comes from the wider parts.
/// Zero and unrecorded parts get no width and no gap.
List<({double left, double width})?> segmentSpans(
  List<int?> values,
  double width, {
  double gap = 2,
  double minWidth = 3,
}) {
  final shown = [
    for (var i = 0; i < values.length; i++)
      if ((values[i] ?? 0) > 0) i,
  ];
  final spans = List<({double left, double width})?>.filled(
    values.length,
    null,
  );
  if (shown.isEmpty || width <= 0) return spans;
  final room = math.max(0.0, width - gap * (shown.length - 1));
  final total = shown.fold<int>(0, (sum, i) => sum + values[i]!);
  final floor = math.min(minWidth, room / shown.length);

  final widths = {for (final i in shown) i: room * values[i]! / total};
  final small = {
    for (final i in shown)
      if (widths[i]! < floor) i,
  };
  if (small.isNotEmpty) {
    final taken = floor * small.length;
    final rest = shown.where((i) => !small.contains(i));
    final restTotal = rest.fold<double>(0, (sum, i) => sum + widths[i]!);
    for (final i in shown) {
      widths[i] = small.contains(i)
          ? floor
          : restTotal <= 0
          ? 0
          : widths[i]! * (room - taken) / restTotal;
    }
  }

  var left = 0.0;
  for (final i in shown) {
    spans[i] = (left: left, width: widths[i]!);
    left += widths[i]! + gap;
  }
  return spans;
}

/// A whole split into its parts, as one horizontal bar — tokens by kind, say.
/// Colour is never the only signal: pair it with a [ChartLegend], and let
/// [semanticsLabel] say the split in words.
class SegmentedBar extends StatelessWidget {
  const SegmentedBar({
    required this.segments,
    required this.semanticsLabel,
    this.thickness = 10,
    super.key,
  });

  final List<BarSegment> segments;
  final double thickness;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final ink = ChartInk.of(context);
    return Semantics(
      container: true,
      label: semanticsLabel,
      child: ExcludeSemantics(
        child: SizedBox(
          height: thickness,
          width: double.infinity,
          child: CustomPaint(
            painter: SegmentedBarPainter(
              values: [for (final s in segments) s.value],
              colors: [for (final s in segments) s.color],
              track: ink.track,
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints a [SegmentedBar].
class SegmentedBarPainter extends CustomPainter {
  const SegmentedBarPainter({
    required this.values,
    required this.colors,
    required this.track,
  });

  final List<int?> values;
  final List<Color> colors;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final radius = Radius.circular(math.min(size.height, size.width) / 2);
    final whole = RRect.fromRectAndRadius(Offset.zero & size, radius);
    canvas.drawRRect(whole, Paint()..color = track);
    canvas.save();
    canvas.clipRRect(whole);
    final spans = segmentSpans(values, size.width);
    for (var i = 0; i < spans.length && i < colors.length; i++) {
      final span = spans[i];
      if (span == null || span.width <= 0) continue;
      canvas.drawRect(
        Rect.fromLTWH(span.left, 0, span.width, size.height),
        Paint()..color = colors[i],
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(SegmentedBarPainter oldDelegate) =>
      !_same(oldDelegate.values, values) ||
      !_same(oldDelegate.colors, colors) ||
      oldDelegate.track != track;
}

bool _same<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The key to a [SegmentedBar]: a swatch, the label, the value and its detail
/// per part, wrapping onto as many lines as the width needs. An unrecorded part
/// shows a hollow swatch and [unrecordedLabel] in place of a value.
class ChartLegend extends StatelessWidget {
  const ChartLegend({
    required this.segments,
    this.unrecordedLabel = 'not recorded',
    super.key,
  });

  final List<BarSegment> segments;
  final String unrecordedLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final base = theme.textTheme.bodySmall;
    final muted = base?.copyWith(color: scheme.onSurfaceVariant);
    const tabular = [FontFeature.tabularFigures()];
    return Wrap(
      spacing: Insets.lg,
      runSpacing: Insets.xs,
      children: [
        for (final segment in segments)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: segment.recorded ? segment.color : null,
                  border: segment.recorded
                      ? null
                      : Border.all(color: scheme.outline),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: Insets.xs),
              Flexible(
                child: Text.rich(
                  TextSpan(
                    style: muted?.copyWith(fontFeatures: tabular),
                    children: [
                      TextSpan(text: segment.label),
                      const TextSpan(text: '  '),
                      if (segment.recorded) ...[
                        TextSpan(
                          text: segment.valueLabel ?? '${segment.value}',
                          style: TextStyle(
                            color: scheme.onSurface,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (segment.detail case final detail?)
                          TextSpan(text: '  $detail'),
                      ] else
                        TextSpan(text: unrecordedLabel),
                    ],
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }
}
