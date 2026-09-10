import 'package:flutter/foundation.dart';
import 'package:xterm2/xterm.dart';

import 'package:karmashala_terminal_core/pane_lifecycle.dart';

/// Re-emits [terminal]'s main-buffer scrollback as text plus SGR sequences,
/// each line self-contained and newest first, so [maxBytes] can stop the walk.
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
    final line = _encodeLine(lines[i]);
    // Every line but the first also carries the `\r\n` that joins it on.
    final cost = newestFirst.isEmpty ? line.length : line.length + 2;
    if (newestFirst.isNotEmpty && total + cost > maxBytes) break;
    newestFirst.add(line);
    total += cost;
  }

  // Only reachable if a single line exceeds the cap, which 200 columns cannot.
  if (total > maxBytes) return (encoded: '', linesEncoded: newestFirst.length);
  return (
    encoded: newestFirst.reversed.join('\r\n'),
    linesEncoded: newestFirst.length,
  );
}

bool _isBlank(BufferLine line) {
  for (var i = 0; i < line.length; i++) {
    if (line.getCodePoint(i) != 0) return false;
    // A cell erased with a background set is not blank — it paints.
    if (line.getBackground(i) != 0) return false;
  }
  return true;
}

/// One line as `ESC[0m` followed by one sequence per style run.
String _encodeLine(BufferLine line) {
  final out = StringBuffer('\x1b[0m');

  // The last non-blank cell; everything after it is dropped.
  var end = line.length;
  while (end > 0 &&
      line.getCodePoint(end - 1) == 0 &&
      line.getBackground(end - 1) == 0) {
    end--;
  }
  if (end == 0) return out.toString();

  // Style currently in effect for the parser, which ESC[0m just reset.
  var styleFg = 0;
  var styleBg = 0;
  var styleFlags = 0;

  var cell = 0;
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
