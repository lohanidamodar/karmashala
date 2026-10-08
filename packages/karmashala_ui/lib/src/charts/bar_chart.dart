import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design_tokens.dart';
import 'chart_support.dart';
import 'meters.dart';

/// One bar: what it is called, how big it is, and how to say that.
@immutable
class BarDatum {
  const BarDatum({
    required this.label,
    required this.value,
    this.valueLabel,
    this.color,
  });

  final String label;
  final double value;

  /// The number in words; `value` rounded when null.
  final String? valueLabel;

  /// Overrides the chart's colour for this bar alone.
  final Color? color;

  String get spoken => valueLabel ?? value.round().toString();

  @override
  bool operator ==(Object other) =>
      other is BarDatum &&
      other.label == label &&
      other.value == value &&
      other.valueLabel == valueLabel &&
      other.color == color;

  @override
  int get hashCode => Object.hash(label, value, valueLabel, color);
}

/// Vertical bars over a category axis — one per day, say. Labels are thinned to
/// the ones that fit and dropped under [kChartCompactWidth]; hover or tap a bar
/// for its value.
class BarChart extends StatefulWidget {
  const BarChart({
    required this.bars,
    required this.color,
    required this.semanticsLabel,
    this.maxValue,
    this.height = 120,
    super.key,
  });

  final List<BarDatum> bars;
  final Color color;

  /// The top of the scale; the tallest bar when null.
  final double? maxValue;
  final double height;
  final String semanticsLabel;

  @override
  State<BarChart> createState() => _BarChartState();
}

class _BarChartState extends State<BarChart> {
  int? _selected;

  void _select(int? index) {
    if (index != _selected) setState(() => _selected = index);
  }

  @override
  void didUpdateWidget(BarChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_selected != null && _selected! >= widget.bars.length) _selected = null;
  }

  @override
  Widget build(BuildContext context) {
    final ink = ChartInk.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    return Semantics(
      container: true,
      label: widget.semanticsLabel,
      child: ExcludeSemantics(
        child: SizedBox(
          height: widget.height,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = Size(
                constraints.hasBoundedWidth ? constraints.maxWidth : 240,
                widget.height,
              );
              final geometry = BarGeometry(
                size: size,
                bars: widget.bars,
                axisStyle: ink.axisLabel,
                scaler: scaler,
              );
              final selected = _selected;
              final chosen = selected != null && selected < widget.bars.length
                  ? selected
                  : null;
              return MouseRegion(
                onHover: (event) =>
                    _select(geometry.indexAt(event.localPosition.dx)),
                onExit: (_) => _select(null),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (details) {
                    final hit = geometry.indexAt(details.localPosition.dx);
                    _select(hit == _selected ? null : hit);
                  },
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: CustomPaint(
                          painter: BarChartPainter(
                            geometry: geometry,
                            bars: widget.bars,
                            color: widget.color,
                            ink: ink,
                            maxValue: widget.maxValue,
                            selected: chosen,
                          ),
                        ),
                      ),
                      if (chosen != null)
                        Positioned.fill(
                          child: CustomSingleChildLayout(
                            delegate: ChartTooltipLayout(
                              Offset(
                                geometry.centerOf(chosen),
                                geometry.plot.top + geometry.plot.height / 2,
                              ),
                            ),
                            child: ChartTooltipCard(
                              ink: ink,
                              lines: [
                                widget.bars[chosen].spoken,
                                widget.bars[chosen].label,
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Where each bar of a [BarChart] sits, shared by painter and hit test.
class BarGeometry {
  BarGeometry({
    required this.size,
    required List<BarDatum> bars,
    required TextStyle axisStyle,
    required TextScaler scaler,
  }) : count = bars.length,
       compact = size.width < kChartCompactWidth {
    if (compact || bars.isEmpty) {
      labels = const [];
      plot = Rect.fromLTRB(0, 2, size.width, math.max(2, size.height));
      stride = 1;
      return;
    }
    labels = [
      for (final bar in bars) layoutChartLabel(bar.label, axisStyle, scaler),
    ];
    final labelHeight = labels.fold<double>(0, (h, l) => math.max(h, l.height));
    final widest = labels.fold<double>(0, (w, l) => math.max(w, l.width));
    plot = Rect.fromLTRB(
      0,
      2,
      size.width,
      math.max(2, size.height - labelHeight - 4),
    );
    final slot = plot.width / bars.length;
    stride = slot <= 0
        ? bars.length
        : math.max(1, ((widest + 6) / slot).ceil());
  }

  final Size size;
  final int count;
  final bool compact;
  late final Rect plot;
  late final List<TextPainter> labels;

  /// Every how-many bars a label is drawn, so labels never collide.
  late final int stride;

  double get slot => count == 0 ? 0 : plot.width / count;

  double centerOf(int index) => plot.left + slot * (index + 0.5);

  int? indexAt(double x) {
    if (count == 0 || slot <= 0) return null;
    final index = ((x - plot.left) / slot).floor();
    return index < 0 || index >= count ? null : index;
  }
}

/// Paints a [BarChart].
class BarChartPainter extends CustomPainter {
  BarChartPainter({
    required this.geometry,
    required this.bars,
    required this.color,
    required this.ink,
    this.maxValue,
    this.selected,
  });

  final BarGeometry geometry;
  final List<BarDatum> bars;
  final Color color;
  final ChartInk ink;
  final double? maxValue;
  final int? selected;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = geometry.plot;
    if (plot.width <= 0 || plot.height <= 0) return;
    canvas.drawLine(
      plot.bottomLeft,
      plot.bottomRight,
      Paint()
        ..color = ink.grid
        ..strokeWidth = 1,
    );
    if (bars.isEmpty) return;
    final top =
        maxValue ??
        bars.fold<double>(
          0,
          (m, b) => b.value.isFinite ? math.max(m, b.value) : m,
        );
    final slot = geometry.slot;
    final width = math.max(1.0, math.min(slot * 0.7, 28.0));
    for (var i = 0; i < bars.length; i++) {
      final value = bars[i].value;
      final fraction = top <= 0 || !value.isFinite
          ? 0.0
          : (value / top).clamp(0.0, 1.0);
      final height = plot.height * fraction;
      final x = geometry.centerOf(i) - width / 2;
      final base = bars[i].color ?? color;
      final fill = selected == null || selected == i
          ? base
          : base.withValues(alpha: 0.45);
      if (height > 0) {
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTWH(x, plot.bottom - height, width, height),
            topLeft: const Radius.circular(2),
            topRight: const Radius.circular(2),
          ),
          Paint()..color = fill,
        );
      }
    }
    for (var i = 0; i < geometry.labels.length; i += geometry.stride) {
      final label = geometry.labels[i];
      final left = (geometry.centerOf(i) - label.width / 2)
          .clamp(0.0, math.max(0.0, size.width - label.width))
          .toDouble();
      label.paint(canvas, Offset(left, plot.bottom + 4));
    }
  }

  @override
  bool shouldRepaint(BarChartPainter oldDelegate) => true;
}

/// Labelled horizontal bars, largest first as given — a ranking such as tokens
/// by project, or accounts side by side. Built from widgets, so long labels
/// ellipsise and wrap with the text scale instead of being painted over.
class RankedBars extends StatelessWidget {
  const RankedBars({
    required this.bars,
    required this.color,
    this.maxValue,
    this.labelFlex = 2,
    super.key,
  });

  final List<BarDatum> bars;
  final Color color;
  final double? maxValue;
  final int labelFlex;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final top =
        maxValue ??
        bars.fold<double>(
          0,
          (m, b) => b.value.isFinite ? math.max(m, b.value) : m,
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final bar in bars)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Insets.xxs),
            child: MergeSemantics(
              child: Row(
                children: [
                  Expanded(
                    flex: labelFlex,
                    child: Text(
                      bar.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(width: Insets.sm),
                  Expanded(
                    flex: 3,
                    child: LinearMeter(
                      value: top <= 0 ? 0 : bar.value / top,
                      color: bar.color ?? color,
                      semanticsLabel: bar.spoken,
                    ),
                  ),
                  const SizedBox(width: Insets.sm),
                  Flexible(
                    child: ExcludeSemantics(
                      child: Text(
                        bar.spoken,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
