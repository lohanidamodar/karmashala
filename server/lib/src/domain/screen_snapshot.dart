import 'package:xterm2/core.dart';

/// The escape bytes that rebuild [terminal] in a fresh one of the same size:
/// scrollback, screen, colours, wrap flags, cursor and modes. What a pane is
/// sent when it attaches to a session already running, instead of the raw
/// output — tmux's model. A replay of an inline TUI's relative redraws onto an
/// empty screen stacks its frames (2026-09-24), while this is the screen the
/// program believes it drew, so its next redraw lands where it expects.
///
/// Not carried: hyperlinks, shell-integration marks, tab stops, the title and
/// the saved cursor. Each comes back the next time the program sets it.
String screenSnapshot(Terminal terminal) {
  final out = StringBuffer()
    // RIS: every mode to its default, both buffers empty.
    ..write('\x1bc\x1b[3J\x1b[H');
  final width = terminal.viewWidth;
  final main = terminal.mainBuffer;
  _writeLines(out, main, width);
  _moveTo(out, main.cursorY, main.cursorX);

  if (terminal.isUsingAltBuffer) {
    final alt = terminal.altBuffer;
    // 1049 saves the main cursor placed above, then clears the alternate one.
    out.write('\x1b[?1049h');
    for (var row = 0; row < terminal.viewHeight; row++) {
      _moveTo(out, row, 0);
      _writeCells(out, alt.lines[row], width, full: false);
    }
  }

  final active = terminal.buffer;
  if (active.marginTop != 0 || active.marginBottom != terminal.viewHeight - 1) {
    // DECSTBM homes the cursor, so it comes before the final position.
    out.write('\x1b[${active.marginTop + 1};${active.marginBottom + 1}r');
  }
  _writeModes(out, terminal);
  out.write(
    _sgr(
      terminal.cursor.foreground,
      terminal.cursor.background,
      terminal.cursor.underlineColor,
      terminal.cursor.attrs,
    ),
  );
  final top = terminal.originMode ? active.marginTop : 0;
  _moveTo(out, active.cursorY - top, active.cursorX);
  return out.toString();
}

/// Every line, oldest first. A line the next one continues is written out to
/// the full width so autowrap joins them, as the program's own output did;
/// any other ends with CR LF, which scrolls the earlier ones into scrollback.
void _writeLines(StringBuffer out, Buffer buffer, int width) {
  final lines = buffer.lines;
  for (var i = 0; i < lines.length; i++) {
    final continues = i + 1 < lines.length && lines[i + 1].isWrapped;
    _writeCells(out, lines[i], width, full: continues);
    if (i + 1 < lines.length && !continues) {
      // Reset first: a line feed under a background colour would paint it.
      out.write('\x1b[0m\r\n');
    }
  }
}

void _writeCells(
  StringBuffer out,
  BufferLine line,
  int width, {
  required bool full,
}) {
  final cells = line.length < width ? line.length : width;
  var end = cells;
  if (!full) {
    while (end > 0 && _isBlank(line, end - 1)) {
      end--;
    }
  }
  var pen = (-1, -1, -1, -1);
  var skipped = 0;
  for (var x = 0; x < end; x++) {
    final codePoint = line.getCodePoint(x);
    final cellWidth = line.getWidth(x);
    // The right half of a wide glyph, written with its left half.
    if (codePoint == 0 &&
        cellWidth == 0 &&
        x > 0 &&
        line.getWidth(x - 1) == 2) {
      continue;
    }
    if (!full && _isBlank(line, x)) {
      skipped++;
      continue;
    }
    if (skipped > 0) {
      // A gap the program moved over stays a gap, not spaces.
      out.write('\x1b[${skipped}C');
      skipped = 0;
    }
    final style = (
      line.getForeground(x),
      line.getBackground(x),
      line.getUnderlineColor(x),
      line.getAttributes(x) & CellAttr.visualMask,
    );
    if (style != pen) {
      out.write(_sgr(style.$1, style.$2, style.$3, style.$4));
      pen = style;
    }
    out.writeCharCode(codePoint == 0 ? 0x20 : codePoint);
    final combining = line.getCombiningCharacters(x);
    if (combining != null) out.write(combining);
  }
  out.write('\x1b[0m');
}

bool _isBlank(BufferLine line, int x) =>
    line.getCodePoint(x) == 0 &&
    line.getBackground(x) == 0 &&
    line.getAttributes(x) & CellAttr.visualMask == 0;

void _moveTo(StringBuffer out, int row, int column) =>
    out.write('\x1b[${row + 1};${column + 1}H');

String _sgr(int foreground, int background, int underline, int attrs) {
  final codes = <String>['0'];
  void flag(int bit, String code) {
    if (attrs & bit != 0) codes.add(code);
  }

  flag(CellAttr.bold, '1');
  flag(CellAttr.faint, '2');
  flag(CellAttr.italic, '3');
  flag(CellAttr.underline, '4');
  flag(CellAttr.doubleUnderline, '4:2');
  flag(CellAttr.undercurl, '4:3');
  flag(CellAttr.dottedUnderline, '4:4');
  flag(CellAttr.dashedUnderline, '4:5');
  flag(CellAttr.blink, '5');
  flag(CellAttr.inverse, '7');
  flag(CellAttr.invisible, '8');
  flag(CellAttr.strikethrough, '9');
  flag(CellAttr.framed, '51');
  flag(CellAttr.encircled, '52');
  flag(CellAttr.overline, '53');
  final fg = _color(foreground, base: 30, bright: 90, extended: 38);
  if (fg != null) codes.add(fg);
  final bg = _color(background, base: 40, bright: 100, extended: 48);
  if (bg != null) codes.add(bg);
  final ul = _color(underline, base: null, bright: null, extended: 58);
  if (ul != null) codes.add(ul);
  return '\x1b[${codes.join(';')}m';
}

/// Null for the default colour, which `0` already restored.
String? _color(
  int color, {
  required int? base,
  required int? bright,
  required int extended,
}) {
  final value = color & CellColor.valueMask;
  switch (color & CellColor.typeMask) {
    case CellColor.named:
      if (base == null || bright == null) return '$extended;5;$value';
      return value < 8 ? '${base + value}' : '${bright + value - 8}';
    case CellColor.palette:
      return '$extended;5;$value';
    case CellColor.rgb:
      return '$extended;2;${(value >> 16) & 0xff};${(value >> 8) & 0xff};'
          '${value & 0xff}';
    default:
      return null;
  }
}

void _writeModes(StringBuffer out, Terminal t) {
  void private(int mode, bool on) => out.write('\x1b[?$mode${on ? 'h' : 'l'}');
  if (t.cursorKeysMode) private(1, true);
  if (t.reverseDisplayMode) private(5, true);
  if (t.originMode) private(6, true);
  if (!t.autoWrapMode) private(7, false);
  if (t.cursorBlinkMode) private(12, true);
  if (!t.cursorVisibleMode) private(25, false);
  if (t.backarrowKeyMode) private(67, true);
  if (t.reportFocusMode) private(1004, true);
  if (t.altBufferMouseScrollMode) private(1007, true);
  if (t.bracketedPasteMode) private(2004, true);
  if (t.insertMode) out.write('\x1b[4h');
  if (t.lineFeedMode) out.write('\x1b[20h');
  if (t.appKeypadMode) out.write('\x1b=');
  switch (t.mouseMode) {
    case MouseMode.none:
      break;
    case MouseMode.clickOnly:
      private(9, true);
    case MouseMode.upDownScroll:
      private(1000, true);
    case MouseMode.upDownScrollDrag:
      private(1002, true);
    case MouseMode.upDownScrollMove:
      private(1003, true);
  }
  switch (t.mouseReportMode) {
    case MouseReportMode.normal:
      break;
    case MouseReportMode.utf:
      private(1005, true);
    case MouseReportMode.sgr:
      private(1006, true);
    case MouseReportMode.sgrPixels:
      private(1016, true);
    case MouseReportMode.urxvt:
      private(1015, true);
  }
  // Pushed, not set: a program that pops its flags on exit then finds the
  // default beneath them, as it would have.
  if (t.kittyKeyboardMode != 0) out.write('\x1b[>${t.kittyKeyboardMode}u');
  if (t.modifyOtherKeysMode != 0) {
    out.write('\x1b[>4;${t.modifyOtherKeysMode}m');
  }
}
