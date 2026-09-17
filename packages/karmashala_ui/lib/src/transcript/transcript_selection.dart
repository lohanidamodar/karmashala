import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

/// Copies a selection the way it reads; Flutter's delegates butt texts together.
/// One line joins with a space, lines with a newline, blocks drawn apart with a
/// blank line — but not two many-celled lines, which are a list or a table.
class ReadingOrderSelectionDelegate extends StaticSelectionContainerDelegate {
  ReadingOrderSelectionDelegate({this.trailing = '', this.outermost = false});

  /// Written after the content, because the parent will butt the next group on.
  final String trailing;

  /// The group the selection area itself talks to: it trims the ends, and
  /// always has edge points.
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

  /// Each nested delegate tells its parent a frame late, and nothing schedules
  /// that frame: a drawn row stayed unselectable until something else moved.
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

  /// Flutter's area reads both edge points on select-all and throws when a row
  /// kept alive off-screen has none; the outermost group always answers one.
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

  /// The same gap one level down: the base class reads edge points an
  /// off-screen child does not have.
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
    for (var i = math.min(start, end); i <= math.max(start, end); i++) {
      didReceiveSelectionEventFor(selectable: selectables[i]);
    }
  }

  static double _bottomOf(List<(Rect, String)> line) =>
      line.map((cell) => cell.$1.bottom).reduce(math.max);

  static bool _sameLine(Rect a, Rect b) =>
      math.min(a.bottom, b.bottom) - math.max(a.top, b.top) > 1;

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

/// One selection over a whole conversation, across blocks and across messages.
/// Rows draw plain [Text] and put chrome in a [SelectionContainer.disabled];
/// only built rows can be selected.
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
