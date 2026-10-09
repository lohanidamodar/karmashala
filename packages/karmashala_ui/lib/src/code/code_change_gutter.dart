import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';

import '../design_tokens.dart';

/// What happened to one line of a buffer since the version it is compared
/// with, as the gutter beside its number draws it.
enum CodeLineChange {
  /// A new line.
  added,

  /// A line that replaced others.
  modified,

  /// Lines were taken out just above this one.
  removedAbove,
}

/// The change bars beside the line numbers: a bar per added or modified
/// line, a wedge where lines were taken out. Drawn at the positions the
/// numbers are, so they stay against their code when lines wrap.
class CodeChangeGutter extends StatelessWidget {
  const CodeChangeGutter({
    required this.notifier,
    required this.marks,
    this.onTapLine,
    super.key,
  });

  /// The column's width: a gap clear of the numbers, then the bar.
  static const double width = Insets.smd;

  final CodeIndicatorValueNotifier notifier;

  /// By 0-based line index.
  final Map<int, CodeLineChange> marks;

  /// A marked line was tapped, by its 0-based index.
  final ValueChanged<int>? onTapLine;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final semantic = SemanticColors.of(context);
    final paint = CustomPaint(
      size: const Size(width, double.infinity),
      painter: _ChangeBars(
        notifier: notifier,
        marks: marks,
        added: semantic.diffAdded,
        modified: scheme.primary,
        removed: semantic.diffRemoved,
      ),
    );
    final onTap = onTapLine;
    if (onTap == null) return paint;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) {
        final y = details.localPosition.dy;
        for (final paragraph in notifier.value?.paragraphs ?? const []) {
          if (y >= paragraph.top && y < paragraph.bottom) {
            if (marks.containsKey(paragraph.index)) onTap(paragraph.index);
            return;
          }
        }
      },
      child: paint,
    );
  }
}

class _ChangeBars extends CustomPainter {
  _ChangeBars({
    required this.notifier,
    required this.marks,
    required this.added,
    required this.modified,
    required this.removed,
  }) : super(repaint: notifier);

  final CodeIndicatorValueNotifier notifier;
  final Map<int, CodeLineChange> marks;
  final Color added;
  final Color modified;
  final Color removed;

  static const _bar = Insets.tight;

  /// Clear of the line numbers on its left.
  static const _gap = Insets.xs;

  @override
  void paint(Canvas canvas, Size size) {
    if (marks.isEmpty) return;
    final fill = Paint();
    for (final paragraph in notifier.value?.paragraphs ?? const []) {
      final change = marks[paragraph.index];
      if (change == null) continue;
      switch (change) {
        case CodeLineChange.added || CodeLineChange.modified:
          fill.color = change == CodeLineChange.added ? added : modified;
          canvas.drawRect(
            Rect.fromLTWH(_gap, paragraph.top, _bar, paragraph.height),
            fill,
          );
        case CodeLineChange.removedAbove:
          fill.color = removed;
          final top = paragraph.top;
          canvas.drawPath(
            Path()
              ..moveTo(_gap, top - Insets.xs)
              ..lineTo(size.width, top)
              ..lineTo(_gap, top + Insets.xs)
              ..close(),
            fill,
          );
      }
    }
  }

  @override
  bool shouldRepaint(_ChangeBars old) =>
      old.marks != marks ||
      old.added != added ||
      old.modified != modified ||
      old.removed != removed;
}
