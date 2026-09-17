import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

/// Copies what is selected under it the way it reads. Flutter's own delegates
/// butt one text against the next, so two paragraphs copy as one run-on line.
///
/// Texts on one line are joined with a space, lines with a newline, and blocks
/// — anything drawn with air between — with a blank line. Two lines of several
/// cells each are a list or a table, and stay single-spaced.
class ReadingOrderSelectionDelegate extends StaticSelectionContainerDelegate {
  ReadingOrderSelectionDelegate({this.trailing = '', this.outermost = false});

  /// Written after the content: what separates this group from the next one,
  /// which a parent delegate will butt against it.
  final String trailing;

  /// Whether this is the group the selection area itself talks to: the one
  /// that drops the space at either end, and that always has edge points.
  final bool outermost;

  /// The least air between two lines that reads as a new block. Below the
  /// Markdown sheet's block spacing, above a tight list's none.
  static const double _blockGap = 6;

  @override
  SelectedContent? getSelectedContent() {
    final lines = <List<(Rect, String)>>[];
    for (final selectable in selectables) {
      final text = selectable.getSelectedContent()?.plainText;
      if (text == null || text.isEmpty) continue;
      final rect = _rectOf(selectable);
      if (lines.isNotEmpty && _sameLine(lines.last.last.$1, rect)) {
        lines.last.add((rect, text));
      } else {
        lines.add([(rect, text)]);
      }
    }
    if (lines.isEmpty) return null;

    final buffer = StringBuffer();
    for (var i = 0; i < lines.length; i++) {
      if (i > 0) {
        final above = lines[i - 1];
        final gap = lines[i].first.$1.top - _bottomOf(above);
        final tabular = above.length > 1 && lines[i].length > 1;
        buffer.write(!tabular && gap >= _blockGap ? '\n\n' : '\n');
      }
      buffer.writeAll([
        for (final (_, text) in lines[i]) text.trimRight(),
      ], ' ');
    }
    buffer.write(trailing);
    final text = buffer.toString();
    return SelectedContent(plainText: outermost ? text.trim() : text);
  }

  /// A delegate takes in new text after the frame that built it, and only tells
  /// its parent then — so each level of nesting waits for one more frame, which
  /// nothing else asks for. Without these a row could sit drawn and unselectable
  /// until the next thing moved.
  @override
  void add(Selectable selectable) {
    super.add(selectable);
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  @override
  void didChangeSelectables() {
    super.didChangeSelectables();
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  /// How far outside the container an edge that cannot be placed is put.
  static const double _offScreen = 10000;

  /// A row scrolled away with a selection in it is kept alive off-screen, and
  /// a selection that starts or ends there reports no edge point. Flutter's
  /// own area assumes both exist and throws on select-all, so the outermost
  /// group answers with a point far outside itself instead of none.
  @override
  SelectionGeometry getSelectionGeometry() {
    final geometry = super.getSelectionGeometry();
    if (!outermost || !geometry.hasSelection || !hasSize) return geometry;
    if (geometry.startSelectionPoint != null &&
        geometry.endSelectionPoint != null) {
      return geometry;
    }
    return geometry.copyWith(
      startSelectionPoint:
          geometry.startSelectionPoint ??
          const SelectionPoint(
            localPosition: Offset(0, -_offScreen),
            lineHeight: 0,
            handleType: TextSelectionHandleType.left,
          ),
      endSelectionPoint:
          geometry.endSelectionPoint ??
          SelectionPoint(
            localPosition: Offset(
              containerSize.width,
              containerSize.height + _offScreen,
            ),
            lineHeight: 0,
            handleType: TextSelectionHandleType.right,
          ),
    );
  }

  /// The same gap one level down: the base class reads its children's edge
  /// points without asking whether an off-screen child has any.
  @override
  void didReceiveSelectionBoundaryEvents() {
    final start = currentSelectionStartIndex;
    final end = currentSelectionEndIndex;
    if (start == -1 || end == -1) return;
    final first = selectables[start].value;
    final last = selectables[end].value;
    final offScreen =
        (first.hasSelection && first.startSelectionPoint == null) ||
        (last.hasSelection && last.endSelectionPoint == null);
    if (!offScreen) return super.didReceiveSelectionBoundaryEvents();
    for (
      var i = start < end ? start : end;
      i <= (start < end ? end : start);
      i++
    ) {
      didReceiveSelectionEventFor(selectable: selectables[i]);
    }
  }

  static double _bottomOf(List<(Rect, String)> line) =>
      line.map((cell) => cell.$1.bottom).reduce((a, b) => a > b ? a : b);

  static bool _sameLine(Rect a, Rect b) {
    final overlap =
        (a.bottom < b.bottom ? a.bottom : b.bottom) -
        (a.top > b.top ? a.top : b.top);
    return overlap > 1;
  }

  /// Within this container rather than on the screen: a row kept alive
  /// off-screen has no place there, and still has its layout.
  Rect _rectOf(Selectable selectable) {
    var rect = selectable.boundingBoxes.first;
    for (final box in selectable.boundingBoxes.skip(1)) {
      rect = rect.expandToInclude(box);
    }
    return MatrixUtils.transformRect(getTransformFrom(selectable), rect);
  }
}

/// A run of selectable text that copies in reading order — one message, or one
/// Markdown body. It must sit under a [SelectionArea] to select at all.
class TranscriptSelectionGroup extends StatefulWidget {
  const TranscriptSelectionGroup({
    required this.child,
    this.endsTurn = false,
    super.key,
  });

  final Widget child;

  /// Whether a blank line follows this group when the selection runs past it:
  /// true for a whole message, so two turns never copy as one.
  final bool endsTurn;

  @override
  State<TranscriptSelectionGroup> createState() =>
      _TranscriptSelectionGroupState();
}

class _TranscriptSelectionGroupState extends State<TranscriptSelectionGroup> {
  late final _delegate = ReadingOrderSelectionDelegate(
    trailing: widget.endsTurn ? '\n\n' : '',
  );

  @override
  void dispose() {
    _delegate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SelectionContainer(delegate: _delegate, child: widget.child);
}

/// One selection over a whole conversation: a drag runs across blocks and
/// across messages, and the platform's copy and select-all chords work on it.
///
/// Rows under it draw plain [Text]; chrome that should not be copied sits in a
/// [SelectionContainer.disabled]. Only rows that are built can be selected.
class TranscriptSelectionArea extends StatefulWidget {
  const TranscriptSelectionArea({required this.child, super.key});

  final Widget child;

  @override
  State<TranscriptSelectionArea> createState() =>
      _TranscriptSelectionAreaState();
}

class _TranscriptSelectionAreaState extends State<TranscriptSelectionArea> {
  final _whole = ReadingOrderSelectionDelegate(outermost: true);

  @override
  void dispose() {
    _whole.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SelectionArea(
    child: SelectionContainer(delegate: _whole, child: widget.child),
  );
}
