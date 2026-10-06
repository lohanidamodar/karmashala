import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_icons.dart';
import '../design_tokens.dart';
import 'flowchart_layout.dart';
import 'mermaid_model.dart';

/// A mermaid diagram drawn natively, at its natural size. Wider than the
/// room it is given, it scrolls sideways rather than shrinking text.
class MermaidDiagramView extends StatelessWidget {
  const MermaidDiagramView(this.diagram, {super.key});

  final MermaidParse diagram;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = (theme.textTheme.bodySmall ?? const TextStyle()).copyWith(
      color: theme.colorScheme.onSurface,
      height: 1.25,
    );
    final scaler = MediaQuery.textScalerOf(context);
    final colors = _Colors(theme.colorScheme);
    final picture = switch (diagram) {
      final MermaidFlowchart chart => _FlowchartPicture(
        chart,
        style,
        scaler,
        colors,
      ),
      final MermaidSequence seq => _SequencePicture(seq, style, scaler, colors),
      _ => null,
    };
    if (picture == null) return const SizedBox.shrink();
    final painted = SizedBox.fromSize(
      size: picture.size,
      child: CustomPaint(painter: picture),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (picture.size.width <= constraints.maxWidth) return painted;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: painted,
        );
      },
    );
  }
}

/// A fenced ```mermaid block in a message: the diagram, with its source one
/// tap away and copyable. A diagram that cannot be drawn shows why, and the
/// source.
class MermaidBlock extends StatefulWidget {
  const MermaidBlock(this.source, {super.key});

  final String source;

  @override
  State<MermaidBlock> createState() => _MermaidBlockState();
}

class _MermaidBlockState extends State<MermaidBlock> {
  late MermaidParse _parse = parseMermaid(widget.source);
  var _showSource = false;

  @override
  void didUpdateWidget(MermaidBlock old) {
    super.didUpdateWidget(old);
    if (old.source != widget.source) _parse = parseMermaid(widget.source);
  }

  bool get _drawable =>
      _parse is MermaidFlowchart || _parse is MermaidSequence;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final problem = switch (_parse) {
      MermaidUnsupported(:final type) =>
        'Mermaid "$type" diagrams are not drawn here yet; the source is below.',
      MermaidError(:final reason) => '$reason The source is below.',
      _ => null,
    };
    final source = Container(
      key: const ValueKey('mermaid-source'),
      width: double.infinity,
      padding: const EdgeInsets.all(Insets.sm),
      child: SelectableText(widget.source.trimRight(), style: MonoStyles.label),
    );
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: dark ? scheme.surfaceContainerLowest : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: Insets.sm),
            child: Row(
              children: [
                Icon(AppIcons.treeStructure, size: 14, color: scheme.outline),
                const SizedBox(width: Insets.xs),
                Expanded(
                  child: Text(
                    'mermaid',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.outline,
                    ),
                  ),
                ),
                if (_drawable)
                  IconButton(
                    key: const ValueKey('mermaid-toggle'),
                    tooltip: _showSource ? 'Show diagram' : 'Show source',
                    iconSize: 16,
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      _showSource ? AppIcons.treeStructure : AppIcons.code,
                    ),
                    onPressed: () => setState(() => _showSource = !_showSource),
                  ),
                IconButton(
                  key: const ValueKey('mermaid-copy'),
                  tooltip: 'Copy source',
                  iconSize: 16,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(AppIcons.copy),
                  onPressed: () => Clipboard.setData(
                    ClipboardData(text: widget.source.trimRight()),
                  ),
                ),
              ],
            ),
          ),
          if (problem != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
              child: Text(
                problem,
                key: const ValueKey('mermaid-problem'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            source,
          ] else if (_showSource)
            source
          else
            Padding(
              key: const ValueKey('mermaid-diagram'),
              padding: const EdgeInsets.fromLTRB(
                Insets.sm,
                0,
                Insets.sm,
                Insets.sm,
              ),
              child: Semantics(
                label: 'Mermaid diagram',
                child: MermaidDiagramView(_parse),
              ),
            ),
        ],
      ),
    );
  }
}

class _Colors {
  _Colors(ColorScheme scheme)
    : fill = scheme.surfaceContainerHigh,
      stroke = scheme.outline,
      line = scheme.onSurfaceVariant,
      note = scheme.tertiaryContainer,
      ground = scheme.surface;

  final Color fill;
  final Color stroke;
  final Color line;
  final Color note;
  final Color ground;
}

abstract class _Picture extends CustomPainter {
  Size get size;

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

TextPainter _text(
  String text,
  TextStyle style,
  TextScaler scaler, {
  double maxWidth = 220,
}) => TextPainter(
  text: TextSpan(text: text, style: style),
  textAlign: TextAlign.center,
  textDirection: TextDirection.ltr,
  textScaler: scaler,
)..layout(maxWidth: maxWidth);

void _paintLine(
  Canvas canvas,
  List<Offset> points,
  Paint paint, {
  bool dashed = false,
}) {
  if (!dashed) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, paint);
    return;
  }
  for (var i = 0; i + 1 < points.length; i++) {
    final a = points[i];
    final b = points[i + 1];
    final length = (b - a).distance;
    if (length == 0) continue;
    final step = (b - a) / length;
    for (var d = 0.0; d < length; d += 8) {
      final end = math.min(d + 4, length);
      canvas.drawLine(a + step * d, a + step * end, paint);
    }
  }
}

void _paintArrowHead(
  Canvas canvas,
  Offset tip,
  Offset from,
  Color color, {
  bool open = false,
}) {
  final d = tip - from;
  if (d.distance == 0) return;
  final u = d / d.distance;
  final n = Offset(-u.dy, u.dx);
  final base = tip - u * 9;
  final path = Path()
    ..moveTo(tip.dx, tip.dy)
    ..lineTo((base + n * 4.5).dx, (base + n * 4.5).dy)
    ..lineTo((base - n * 4.5).dx, (base - n * 4.5).dy)
    ..close();
  canvas.drawPath(
    path,
    Paint()
      ..color = color
      ..style = open ? PaintingStyle.stroke : PaintingStyle.fill
      ..strokeWidth = 1.2,
  );
}

class _FlowchartPicture extends _Picture {
  _FlowchartPicture(this.chart, TextStyle style, TextScaler scaler, this.colors)
    : _labels = {
        for (final n in chart.nodes) n.id: _text(n.label, style, scaler),
      },
      _edgeLabels = [
        for (final e in chart.edges)
          e.label == null
              ? null
              : _text(e.label!, style, scaler, maxWidth: 160),
      ] {
    final sizes = {
      for (final n in chart.nodes) n.id: _nodeSize(n.shape, _labels[n.id]!.size),
    };
    _layout = layoutFlowchart(chart, sizes);
  }

  final MermaidFlowchart chart;
  final _Colors colors;
  final Map<String, TextPainter> _labels;
  final List<TextPainter?> _edgeLabels;
  late final FlowchartLayout _layout;

  static const _pad = 4.0;

  @override
  Size get size => Size(
    _layout.size.width + _pad * 2,
    _layout.size.height + _pad * 2,
  );

  static Size _nodeSize(MermaidShape shape, Size text) {
    final w = text.width + 24;
    final h = text.height + 16;
    return switch (shape) {
      MermaidShape.diamond => Size(w * 1.5, h * 1.6),
      MermaidShape.circle => Size.square(math.max(w, h) + 4),
      MermaidShape.hexagon || MermaidShape.parallelogram => Size(w + 20, h),
      MermaidShape.flag => Size(w + 12, h),
      _ => Size(w, h),
    };
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.translate(_pad, _pad);
    for (final (i, edge) in chart.edges.indexed) {
      final route = _layout.edges[i];
      final paint = Paint()
        ..color = colors.line
        ..style = PaintingStyle.stroke
        ..strokeWidth = edge.line == MermaidLine.thick ? 2.5 : 1.2;
      _paintLine(
        canvas,
        route,
        paint,
        dashed: edge.line == MermaidLine.dotted,
      );
      if (edge.arrow && route.length >= 2) {
        _paintArrowHead(canvas, route.last, route[route.length - 2], colors.line);
      }
    }
    for (final node in chart.nodes) {
      final box = _layout.nodes[node.id]!;
      _paintShape(canvas, node.shape, box);
      final label = _labels[node.id]!;
      label.paint(canvas, box.center - Offset(label.width / 2, label.height / 2));
    }
    for (final (i, label) in _edgeLabels.indexed) {
      if (label == null) continue;
      final at = _midpoint(_layout.edges[i]);
      final box = Rect.fromCenter(
        center: at,
        width: label.width + 8,
        height: label.height + 4,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(box, const Radius.circular(3)),
        Paint()..color = colors.ground,
      );
      label.paint(canvas, at - Offset(label.width / 2, label.height / 2));
    }
  }

  void _paintShape(Canvas canvas, MermaidShape shape, Rect r) {
    final fill = Paint()..color = colors.fill;
    final stroke = Paint()
      ..color = colors.stroke
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    void both(Path path) {
      canvas
        ..drawPath(path, fill)
        ..drawPath(path, stroke);
    }

    switch (shape) {
      case MermaidShape.rect:
        both(Path()..addRRect(RRect.fromRectAndRadius(r, const Radius.circular(3))));
      case MermaidShape.round:
        both(Path()..addRRect(RRect.fromRectAndRadius(r, const Radius.circular(10))));
      case MermaidShape.stadium:
        both(Path()..addRRect(RRect.fromRectAndRadius(r, Radius.circular(r.height / 2))));
      case MermaidShape.subroutine:
        both(Path()..addRect(r));
        canvas
          ..drawLine(r.topLeft.translate(7, 0), r.bottomLeft.translate(7, 0), stroke)
          ..drawLine(r.topRight.translate(-7, 0), r.bottomRight.translate(-7, 0), stroke);
      case MermaidShape.cylinder:
        const lip = 6.0;
        both(
          Path()
            ..addRect(Rect.fromLTRB(r.left, r.top + lip, r.right, r.bottom - lip))
            ..addOval(Rect.fromLTRB(r.left, r.bottom - lip * 2, r.right, r.bottom)),
        );
        both(Path()..addOval(Rect.fromLTRB(r.left, r.top, r.right, r.top + lip * 2)));
      case MermaidShape.circle:
        both(Path()..addOval(r));
      case MermaidShape.diamond:
        both(
          Path()
            ..moveTo(r.center.dx, r.top)
            ..lineTo(r.right, r.center.dy)
            ..lineTo(r.center.dx, r.bottom)
            ..lineTo(r.left, r.center.dy)
            ..close(),
        );
      case MermaidShape.hexagon:
        both(
          Path()
            ..moveTo(r.left + 10, r.top)
            ..lineTo(r.right - 10, r.top)
            ..lineTo(r.right, r.center.dy)
            ..lineTo(r.right - 10, r.bottom)
            ..lineTo(r.left + 10, r.bottom)
            ..lineTo(r.left, r.center.dy)
            ..close(),
        );
      case MermaidShape.flag:
        both(
          Path()
            ..moveTo(r.left, r.top)
            ..lineTo(r.right, r.top)
            ..lineTo(r.right, r.bottom)
            ..lineTo(r.left, r.bottom)
            ..lineTo(r.left + 12, r.center.dy)
            ..close(),
        );
      case MermaidShape.parallelogram:
        both(
          Path()
            ..moveTo(r.left + 10, r.top)
            ..lineTo(r.right, r.top)
            ..lineTo(r.right - 10, r.bottom)
            ..lineTo(r.left, r.bottom)
            ..close(),
        );
    }
  }

  static Offset _midpoint(List<Offset> route) {
    var total = 0.0;
    for (var i = 0; i + 1 < route.length; i++) {
      total += (route[i + 1] - route[i]).distance;
    }
    var left = total / 2;
    for (var i = 0; i + 1 < route.length; i++) {
      final step = (route[i + 1] - route[i]).distance;
      if (step >= left && step > 0) {
        return route[i] + (route[i + 1] - route[i]) * (left / step);
      }
      left -= step;
    }
    return route.first;
  }
}

class _SequencePicture extends _Picture {
  _SequencePicture(this.seq, this.style, this.scaler, this.colors) {
    _measure();
  }

  final MermaidSequence seq;
  final TextStyle style;
  final TextScaler scaler;
  final _Colors colors;

  late final Map<String, double> _x;
  late final List<TextPainter> _heads;
  late final double _headHeight;
  late final List<(MermaidStep, double, TextPainter?)> _rows;
  late Size _size;

  static const _pad = 8.0;

  @override
  Size get size => _size;

  void _measure() {
    _heads = [for (final p in seq.participants) _text(p.label, style, scaler)];
    _headHeight = _heads.map((h) => h.height).fold(0.0, math.max) + 16;
    final widths = [for (final h in _heads) math.max(80.0, h.width + 24)];
    final order = {
      for (final (i, p) in seq.participants.indexed) p.id: i,
    };
    final gaps = List.filled(math.max(0, widths.length - 1), 0.0);
    for (var i = 0; i < gaps.length; i++) {
      gaps[i] = (widths[i] + widths[i + 1]) / 2 + 32;
    }
    var number = 0;
    final rows = <(MermaidStep, double, TextPainter?)>[];
    for (final step in seq.steps) {
      switch (step) {
        case MermaidMessage(:final from, :final to, :final text):
          number++;
          final label = _text(
            seq.autonumber ? '$number. $text' : text,
            style,
            scaler,
            maxWidth: 260,
          );
          final a = order[from]!;
          final b = order[to]!;
          if (a != b && (a - b).abs() == 1) {
            final i = math.min(a, b);
            gaps[i] = math.max(gaps[i], label.width + 32);
          }
          rows.add((step, label.height + 26, label));
        case MermaidNote(:final text):
          final label = _text(text, style, scaler, maxWidth: 200);
          rows.add((step, label.height + 24, label));
        case MermaidBlockStart(:final kind, :final label):
          final title = _text(
            label.isEmpty ? kind : '$kind [$label]',
            style.copyWith(fontWeight: FontWeight.w600),
            scaler,
            maxWidth: 300,
          );
          rows.add((step, title.height + 14, title));
        case MermaidBlockDivider(:final label):
          final title = label.isEmpty
              ? null
              : _text('[$label]', style, scaler, maxWidth: 300);
          rows.add((step, (title?.height ?? 0) + 14, title));
        case MermaidBlockEnd():
          rows.add((step, 10, null));
      }
    }
    _rows = rows;
    final x = <String, double>{};
    var cursor = _pad + widths.first / 2 + 16;
    for (final (i, p) in seq.participants.indexed) {
      x[p.id] = cursor;
      if (i < gaps.length) cursor += gaps[i];
    }
    _x = x;
    final right = cursor + widths.last / 2 + 48;
    final height =
        _pad * 2 + _headHeight + 16 + rows.fold(0.0, (s, r) => s + r.$2) + 8;
    _size = Size(right, height);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = colors.stroke
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final line = Paint()
      ..color = colors.line
      ..strokeWidth = 1.2;
    final top = _pad;
    final lifeTop = top + _headHeight;
    final bottom = size.height - _pad;
    for (final (i, p) in seq.participants.indexed) {
      final head = _heads[i];
      final cx = _x[p.id]!;
      _paintLine(
        canvas,
        [Offset(cx, lifeTop), Offset(cx, bottom)],
        Paint()
          ..color = colors.stroke
          ..strokeWidth = 1,
        dashed: true,
      );
      final box = Rect.fromCenter(
        center: Offset(cx, top + _headHeight / 2),
        width: math.max(80, head.width + 24),
        height: _headHeight,
      );
      final rrect = RRect.fromRectAndRadius(
        box,
        Radius.circular(p.actor ? _headHeight / 2 : 3),
      );
      canvas
        ..drawRRect(rrect, Paint()..color = colors.fill)
        ..drawRRect(rrect, stroke);
      head.paint(canvas, box.center - Offset(head.width / 2, head.height / 2));
    }
    final left = _x.values.reduce(math.min) - 60;
    final right = _x.values.reduce(math.max) + 60;
    final frames = <double>[];
    var y = lifeTop + 16;
    for (final (step, height, label) in _rows) {
      switch (step) {
        case MermaidMessage(:final from, :final to, :final dashed, :final end):
          final x1 = _x[from]!;
          final x2 = _x[to]!;
          final lineY = y + height - 8;
          if (label != null) {
            final mid = x1 == x2 ? x1 + 40 : (x1 + x2) / 2;
            label.paint(canvas, Offset(mid - label.width / 2, y + 2));
          }
          final points = x1 == x2
              ? [
                  Offset(x1, lineY - 10),
                  Offset(x1 + 30, lineY - 10),
                  Offset(x1 + 30, lineY),
                  Offset(x1 + 2, lineY),
                ]
              : [Offset(x1, lineY), Offset(x2 + (x2 > x1 ? -1 : 1), lineY)];
          _paintLine(canvas, points, line, dashed: dashed);
          final tip = points.last;
          final from0 = points[points.length - 2];
          switch (end) {
            case MermaidMessageEnd.arrow:
              _paintArrowHead(canvas, tip, from0, colors.line);
            case MermaidMessageEnd.async:
              _paintArrowHead(canvas, tip, from0, colors.line, open: true);
            case MermaidMessageEnd.cross:
              canvas
                ..drawLine(tip.translate(-5, -5), tip.translate(5, 5), line)
                ..drawLine(tip.translate(-5, 5), tip.translate(5, -5), line);
            case MermaidMessageEnd.open:
              break;
          }
        case MermaidNote(:final over, :final side):
          final xs = [for (final id in over) _x[id]!];
          final w = label!.width + 16;
          final double l;
          final double r;
          if (side == 'left') {
            r = xs.first - 8;
            l = r - w;
          } else if (side == 'right') {
            l = xs.first + 8;
            r = l + w;
          } else {
            final lo = xs.reduce(math.min);
            final hi = xs.reduce(math.max);
            l = math.min(lo - 20, (lo + hi) / 2 - w / 2);
            r = math.max(hi + 20, (lo + hi) / 2 + w / 2);
          }
          final box = Rect.fromLTRB(l, y + 4, r, y + height - 6);
          canvas
            ..drawRect(box, Paint()..color = colors.note)
            ..drawRect(box, stroke);
          label.paint(
            canvas,
            box.center - Offset(label.width / 2, label.height / 2),
          );
        case MermaidBlockStart():
          frames.add(y + 2);
          label?.paint(canvas, Offset(left + 6, y + 6));
        case MermaidBlockDivider():
          _paintLine(
            canvas,
            [Offset(left, y + 4), Offset(right, y + 4)],
            Paint()
              ..color = colors.stroke
              ..strokeWidth = 1,
            dashed: true,
          );
          label?.paint(canvas, Offset(left + 6, y + 6));
        case MermaidBlockEnd():
          if (frames.isNotEmpty) {
            final start = frames.removeLast();
            canvas.drawRect(
              Rect.fromLTRB(left, start, right, y + 4),
              stroke,
            );
          }
      }
      y += height;
    }
  }
}
