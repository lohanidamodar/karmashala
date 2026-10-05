import 'dart:math' show max;

import 'package:xterm2/xterm.dart';

/// Shortest run of one glyph out to the last column that reads as drawn to
/// the width — a rule — rather than as text that happened to end there.
const kMinFillCells = 4;

/// Whether [row] is filled to its last column by a fill of [kMinFillCells]
/// or more — never a word that soft-wrapping happened to break.
bool endsInFill(BufferLine row) =>
    row.length - fillStart(row, row.length) >= kMinFillCells;

/// Where [line]'s trailing fill starts, or [end] when it has none: trailing
/// spaces, or one glyph other than a letter or digit repeated out to the last
/// column.
int fillStart(BufferLine line, int end) {
  final last = end - 1;
  final codePoint = line.getCodePoint(last);
  if (codePoint == 0 || line.getWidth(last) != 1) return end;
  var start = last;
  while (start > 0 && _sameCell(line, start - 1, last)) {
    start--;
  }
  if (codePoint == 0x20) return start;
  final drawn =
      end == line.length &&
      end - start >= kMinFillCells &&
      !_wordGlyph.hasMatch(String.fromCharCode(codePoint));
  return drawn ? start : end;
}

/// How many cells [next] opens with that are the rest of [row]'s fill: what
/// a narrower grid wrapped onto a row of its own. Zero unless [next]
/// continues a [row] that [endsInFill], and for spaces unless they are all
/// [next] holds.
int fillLeftover(BufferLine row, BufferLine next) {
  if (!next.isWrapped || !endsInFill(row)) return 0;
  final last = row.length - 1;
  var cell = 0;
  while (cell < next.length &&
      next.getCodePoint(cell) == row.getCodePoint(last) &&
      next.getWidth(cell) == 1 &&
      next.getForeground(cell) == row.getForeground(last) &&
      next.getBackground(cell) == row.getBackground(last) &&
      next.getAttributes(cell) == row.getAttributes(last)) {
    cell++;
  }
  // Spaces before text are its indent as much as any leftover: kept.
  if (row.getCodePoint(last) == 0x20 && cell < next.getTrimmedLength()) {
    return 0;
  }
  return cell;
}

/// Before [buffer] reflows to [columns]: a row whose fill runs past the new
/// edge keeps its rule to that edge and its spaces not at all, and ends its
/// line, so neither wraps onto rows of its own and what continued it keeps
/// its own indent.
void cutFillsPast(Buffer buffer, int columns) {
  final lines = buffer.lines;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.length <= columns || line.getTrimmedLength() <= columns) continue;
    if (!endsInFill(line)) continue;
    final start = fillStart(line, line.length);
    // Spaces that paint nothing go; any other fill keeps what shows.
    final blank =
        line.getCodePoint(start) == 0x20 &&
        line.getBackground(start) == 0 &&
        line.getAttributes(start) == 0;
    final cutAt = blank
        ? start
        : max(columns, (start ~/ columns + 1) * columns);
    for (var cell = cutAt; cell < line.length; cell++) {
      line.resetCell(cell);
    }
    if (i + 1 < lines.length) lines[i + 1].isWrapped = false;
  }
}

bool _sameCell(BufferLine line, int a, int b) =>
    line.getCodePoint(a) == line.getCodePoint(b) &&
    line.getWidth(a) == 1 &&
    line.getForeground(a) == line.getForeground(b) &&
    line.getBackground(a) == line.getBackground(b) &&
    line.getAttributes(a) == line.getAttributes(b);

/// A letter or digit: a run of one is text, whatever its length.
final _wordGlyph = RegExp(r'[\p{L}\p{N}]', unicode: true);
