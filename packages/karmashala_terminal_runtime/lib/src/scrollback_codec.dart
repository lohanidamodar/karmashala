import 'dart:math' show max;

import 'package:flutter/foundation.dart';
import 'package:xterm2/xterm.dart';

import 'package:karmashala_terminal_core/pane_lifecycle.dart';

import 'row_fill.dart';

/// Re-emits [terminal]'s main-buffer scrollback as text plus SGR sequences,
/// each row self-contained and newest first, so [maxBytes] can stop the walk.
/// Rows of one soft-wrapped line are stored unbroken, to wrap where read back.
String encodeScrollback(
  Terminal terminal, {
  int maxLines = kDurableScrollbackMaxLines,
  int maxBytes = kDurableScrollbackMaxBytes,
}) => encodeScrollbackWithStats(
  terminal,
  maxLines: maxLines,
  maxBytes: maxBytes,
).encoded;

/// [encodeScrollback], plus the buffer lines it had to encode. The count is the
/// performance contract — a save must cost what it stores — so it is exposed.
@visibleForTesting
({String encoded, int linesEncoded}) encodeScrollbackWithStats(
  Terminal terminal, {
  int maxLines = kDurableScrollbackMaxLines,
  int maxBytes = kDurableScrollbackMaxBytes,
}) {
  final buffer = terminal.mainBuffer;
  final lines = buffer.lines;

  // Drop trailing blank lines — the unused remainder of the viewport.
  var end = lines.length;
  while (end > 0 && _isBlank(lines[end - 1])) {
    end--;
  }
  if (end == 0) return (encoded: '', linesEncoded: 0);

  final start = end - maxLines < 0 ? 0 : end - maxLines;

  // Newest first, so the budget can stop the walk. `newestFirst` is reversed
  // before joining, so the stored order is unchanged.
  final newestFirst = <String>[];
  var total = 0;
  for (var i = end - 1; i >= start; i--) {
    // The rest of a fill a narrower grid wrapped is no part of this row.
    final from = i > 0 ? fillLeftover(lines[i - 1], lines[i]) : 0;
    if (from > 0 && from >= lines[i].getTrimmedLength()) continue;
    final newest = newestFirst.isEmpty;
    // Every row but the newest also carries what joins the next one on.
    // A row filled out to its edge is a TUI's drawing even when it ran on
    // (ConPTY sends no line break after one), so it ends its line.
    final joint =
        newest || (_continues(lines[i], lines[i + 1]) && !endsInFill(lines[i]))
        ? ''
        : '\r\n';
    final line = _encodeLine(
      lines[i],
      from: from,
      endsLine: joint.isNotEmpty || newest,
    );
    final cost = line.length + joint.length;
    if (newestFirst.isNotEmpty && total + cost > maxBytes) break;
    newestFirst.add('$line$joint');
    total += cost;
  }

  // Only reachable if a single line exceeds the cap, which 200 columns cannot.
  if (total > maxBytes) return (encoded: '', linesEncoded: newestFirst.length);
  return (
    encoded: newestFirst.reversed.join(),
    linesEncoded: newestFirst.length,
  );
}

/// Whether [next] continues [row] in a shape that reads back so: [row] full
/// (but for a wide glyph that did not fit) and [next] opening on text.
bool _continues(BufferLine row, BufferLine next) {
  if (!next.isWrapped || next.length == 0 || next.getCodePoint(0) == 0) {
    return false;
  }
  var end = row.length;
  while (end > 0 && row.getCodePoint(end - 1) == 0) {
    // A wide glyph's second cell is empty too, and is not a gap.
    if (end > 1 && row.getWidth(end - 2) == 2) break;
    end--;
  }
  if (end == row.length) return true;
  return end == row.length - 1 && next.getWidth(0) == 2;
}

bool _isBlank(BufferLine line) {
  for (var i = 0; i < line.length; i++) {
    if (line.getCodePoint(i) != 0) return false;
    // A cell erased with a background set is not blank — it paints.
    if (line.getBackground(i) != 0) return false;
  }
  return true;
}

/// One line as `ESC[0m` followed by one sequence per style run. A row that
/// [endsLine] keeps its trailing fill (see [fillStart]) to one row when read
/// back narrower, as a TUI would redraw it, instead of wrapping it into more.
String _encodeLine(
  BufferLine line, {
  required bool endsLine,
  int from = 0,
}) {
  final out = StringBuffer('\x1b[0m');

  // The last non-blank cell; everything after it is dropped.
  var end = line.length;
  while (end > 0 &&
      line.getCodePoint(end - 1) == 0 &&
      line.getBackground(end - 1) == 0) {
    end--;
  }
  if (end == 0) return out.toString();
  final fillEnd = end;
  if (endsLine) end = max(from, fillStart(line, end));

  // Style currently in effect for the parser, which ESC[0m just reset.
  var styleFg = 0;
  var styleBg = 0;
  var styleFlags = 0;

  var cell = from;
  while (cell < end) {
    final foreground = line.getForeground(cell);
    final background = line.getBackground(cell);
    final flags = line.getAttributes(cell);
    final blank = line.getCodePoint(cell) == 0;

    // Extend the run while style and blankness hold.
    final runStart = cell;
    final text = StringBuffer();
    var runCells = 0;
    while (cell < end &&
        line.getForeground(cell) == foreground &&
        line.getBackground(cell) == background &&
        line.getAttributes(cell) == flags &&
        (line.getCodePoint(cell) == 0) == blank) {
      final width = line.getWidth(cell);
      final advance = width < 1 ? 1 : width;
      if (!blank) text.writeCharCode(line.getCodePoint(cell));
      runCells += advance;
      cell += advance;
    }

    if (foreground != styleFg || background != styleBg || flags != styleFlags) {
      out.write(_sgr(foreground, background, flags));
      styleFg = foreground;
      styleBg = background;
      styleFlags = flags;
    }

    if (blank) {
      // Erase (which writes this style with an empty code point) then step over,
      // so a gap restores as a genuinely empty cell rather than a space.
      out.write('\x1b[${runCells}X\x1b[${runCells}C');
    } else {
      out.write(text);
    }
    assert(cell > runStart, 'the run must consume at least one cell');
  }

  final codePoint = end < fillEnd ? line.getCodePoint(end) : 0;
  final background = end < fillEnd ? line.getBackground(end) : 0;
  final flags = end < fillEnd ? line.getAttributes(end) : 0;
  // Spaces that paint nothing are dropped: one would wrap onto a row of its
  // own behind text that fills the row it is read back into.
  if (codePoint != 0 && (codePoint != 0x20 || background != 0 || flags != 0)) {
    final foreground = line.getForeground(end);
    if (foreground != styleFg || background != styleBg || flags != styleFlags) {
      out.write(_sgr(foreground, background, flags));
    }
    final glyph = String.fromCharCode(codePoint);
    // The first glyph wraps if the text before it filled the row, so the
    // rest, written with autowrap off, can only overwrite its own row's end.
    out.write(glyph);
    if (fillEnd - end > 1) {
      out.write('\x1b[?7l${glyph * (fillEnd - end - 1)}\x1b[?7h');
    }
  }

  return out.toString();
}


/// The SGR sequence that sets exactly [foreground], [background] and [flags].
/// Every code emitted here is handled by the vendored parser's `_csiHandleSgr`,
/// which is what closes the encode/write round-trip.
String _sgr(int foreground, int background, int flags) {
  final codes = <String>['0'];

  if (flags & CellAttr.bold != 0) codes.add('1');
  if (flags & CellAttr.faint != 0) codes.add('2');
  if (flags & CellAttr.italic != 0) codes.add('3');
  if (flags & CellAttr.underline != 0) codes.add('4');
  if (flags & CellAttr.blink != 0) codes.add('5');
  if (flags & CellAttr.inverse != 0) codes.add('7');
  if (flags & CellAttr.invisible != 0) codes.add('8');
  if (flags & CellAttr.strikethrough != 0) codes.add('9');

  codes.addAll(_colorCodes(foreground, isForeground: true));
  codes.addAll(_colorCodes(background, isForeground: false));

  return '\x1b[${codes.join(';')}m';
}

List<String> _colorCodes(int color, {required bool isForeground}) {
  final value = color & CellColor.valueMask;
  switch (color & CellColor.typeMask) {
    case CellColor.named:
      // 0-7 map to 30-37 / 40-47; 8-15 to the bright ranges 90-97 / 100-107.
      final base = isForeground ? 30 : 40;
      final bright = isForeground ? 90 : 100;
      return [value < 8 ? '${base + value}' : '${bright + (value - 8)}'];
    case CellColor.palette:
      return [isForeground ? '38' : '48', '5', '$value'];
    case CellColor.rgb:
      return [
        isForeground ? '38' : '48',
        '2',
        '${(value >> 16) & 0xFF}',
        '${(value >> 8) & 0xFF}',
        '${value & 0xFF}',
      ];
    default:
      // CellColor.normal — the leading `0` already restored the default.
      return const [];
  }
}
