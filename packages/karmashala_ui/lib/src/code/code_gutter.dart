import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// The rows a gutter of [lineCount] draws in a viewport [height] tall scrolled
/// to [offset] — inclusive, 0-based, and empty as `first > last`.
({int first, int last}) visibleGutterRows({
  required int lineCount,
  required double rowHeight,
  required double offset,
  required double height,
}) {
  if (rowHeight <= 0 || lineCount <= 0) return (first: 0, last: -1);
  final first = math.max(0, offset ~/ rowHeight);
  final last = math.min(
    lineCount - 1,
    ((offset + height) / rowHeight).ceil() - 1,
  );
  return (first: first, last: last);
}

/// The line numbers beside a code surface, painted rather than built, so only
/// the rows on screen cost anything.
class CodeGutter extends StatelessWidget {
  const CodeGutter({
    required this.lineCount,
    required this.rowHeight,
    required this.scroll,
    required this.width,
    required this.style,
    super.key,
  });

  final int lineCount;
  final double rowHeight;

  /// The code's own vertical controller. Taken rather than an offset so
  /// scrolling repaints this and rebuilds nothing.
  final ScrollController scroll;

  final double width;
  final TextStyle style;

  /// How wide a gutter has to be for [lineCount], measured in [style].
  static double widthFor(int lineCount, TextStyle style, TextScaler scaler) {
    final painter = TextPainter(
      text: TextSpan(text: '0' * '$lineCount'.length, style: style),
      textScaler: scaler,
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width + Insets.sm * 2;
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: CustomPaint(
      painter: _GutterPainter(
        lineCount: lineCount,
        rowHeight: rowHeight,
        scroll: scroll,
        style: style,
        scaler: MediaQuery.textScalerOf(context),
      ),
    ),
  );
}

class _GutterPainter extends CustomPainter {
  _GutterPainter({
    required this.lineCount,
    required this.rowHeight,
    required this.scroll,
    required this.style,
    required this.scaler,
  }) : super(repaint: scroll);

  final int lineCount;
  final double rowHeight;
  final ScrollController scroll;
  final TextStyle style;
  final TextScaler scaler;

  double get _offset => scroll.hasClients ? scroll.offset : 0;

  @override
  void paint(Canvas canvas, Size size) {
    if (rowHeight <= 0) return;
    canvas.clipRect(Offset.zero & size);
    final offset = _offset;
    final rows = visibleGutterRows(
      lineCount: lineCount,
      rowHeight: rowHeight,
      offset: offset,
      height: size.height,
    );
    // One painter re-laid out per row, rather than one allocated per line.
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      textAlign: TextAlign.right,
      maxLines: 1,
    );
    for (var line = rows.first; line <= rows.last; line++) {
      painter
        ..text = TextSpan(text: '${line + 1}', style: style)
        ..layout(minWidth: size.width - Insets.sm * 2);
      painter.paint(canvas, Offset(Insets.sm, line * rowHeight - offset));
    }
    painter.dispose();
  }

  @override
  bool shouldRepaint(_GutterPainter old) =>
      old.lineCount != lineCount ||
      old.rowHeight != rowHeight ||
      old.scroll != scroll ||
      old.style != style ||
      old.scaler != scaler;
}
