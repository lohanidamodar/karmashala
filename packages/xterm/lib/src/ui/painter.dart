import 'dart:ui';
import 'package:flutter/painting.dart';
import 'package:meta/meta.dart';
import 'package:quiver/collection.dart';

import 'package:xterm/src/ui/palette_builder.dart';
import 'package:xterm/src/ui/paragraph_cache.dart';
import 'package:xterm/xterm.dart';

/// Encapsulates the logic for painting various terminal elements.
class TerminalPainter {
  TerminalPainter({
    required TerminalTheme theme,
    required TerminalStyle textStyle,
    required TextScaler textScaler,
  })  : _textStyle = textStyle,
        _theme = theme,
        _textScaler = textScaler;

  /// A lookup table from terminal colors to Flutter colors.
  late var _colorPalette = PaletteBuilder(_theme).build();

  /// Size of each character in the terminal.
  late var _cellSize = _measureCharSize();

  /// The cached for cells in the terminal. Should be cleared when the same
  /// cell no longer produces the same visual output. For example, when
  /// [_textStyle] is changed, or when the system font changes.
  ///
  /// Only [paintLinePerCell] uses this now; production painting goes through
  /// [_runCache]. See VENDORED.md.
  final _paragraphCache = ParagraphCache(10240);

  /// Laid-out paragraphs for whole *runs* of same-styled text, keyed
  /// structurally on (text, foreground, background, flags, textScaler).
  ///
  /// A record key means equal keys are equal by value, so — unlike an int hash
  /// key — two different runs can never collide onto one another's paragraph.
  /// Cleared wherever [_paragraphCache] is.
  ///
  /// Sized like upstream's per-cell cache: a full 200x50 viewport where every
  /// cell is its own run is 10 000 entries, and a cache smaller than that
  /// thrashes and re-lays-out every frame (measured: 4096 made the adversarial
  /// corpus 4x *slower* than per-cell painting).
  final _runCache = LruMap<_RunKey, Paragraph>(maximumSize: 10240);

  TerminalStyle get textStyle => _textStyle;
  TerminalStyle _textStyle;
  set textStyle(TerminalStyle value) {
    if (value == _textStyle) return;
    _textStyle = value;
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
    _runCache.clear();
  }

  TextScaler get textScaler => _textScaler;
  TextScaler _textScaler = TextScaler.linear(1.0);
  set textScaler(TextScaler value) {
    if (value == _textScaler) return;
    _textScaler = value;
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
    _runCache.clear();
  }

  TerminalTheme get theme => _theme;
  TerminalTheme _theme;
  set theme(TerminalTheme value) {
    if (value == _theme) return;
    _theme = value;
    _colorPalette = PaletteBuilder(value).build();
    _paragraphCache.clear();
    _runCache.clear();
  }

  Size _measureCharSize() {
    const test = 'mmmmmmmmmm';

    final textStyle = _textStyle.toTextStyle();
    final builder = ParagraphBuilder(textStyle.getParagraphStyle());
    builder.pushStyle(
      textStyle.getTextStyle(textScaler: _textScaler),
    );
    builder.addText(test);

    final paragraph = builder.build();
    paragraph.layout(ParagraphConstraints(width: double.infinity));

    final result = Size(
      paragraph.maxIntrinsicWidth / test.length,
      paragraph.height,
    );

    paragraph.dispose();
    return result;
  }

  /// The size of each character in the terminal.
  Size get cellSize => _cellSize;

  /// When the set of font available to the system changes, call this method to
  /// clear cached state related to font rendering.
  void clearFontCache() {
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
    _runCache.clear();
  }

  /// Paints the cursor based on the current cursor type.
  void paintCursor(
    Canvas canvas,
    Offset offset, {
    required TerminalCursorType cursorType,
    bool hasFocus = true,
  }) {
    final paint = Paint()
      ..color = _theme.cursor
      ..strokeWidth = 1;

    if (!hasFocus) {
      paint.style = PaintingStyle.stroke;
      canvas.drawRect(offset & _cellSize, paint);
      return;
    }

    switch (cursorType) {
      case TerminalCursorType.block:
        paint.style = PaintingStyle.fill;
        canvas.drawRect(offset & _cellSize, paint);
        return;
      case TerminalCursorType.underline:
        return canvas.drawLine(
          Offset(offset.dx, _cellSize.height - 1),
          Offset(offset.dx + _cellSize.width, _cellSize.height - 1),
          paint,
        );
      case TerminalCursorType.verticalBar:
        return canvas.drawLine(
          Offset(offset.dx, 0),
          Offset(offset.dx, _cellSize.height),
          paint,
        );
    }
  }

  @pragma('vm:prefer-inline')
  void paintHighlight(Canvas canvas, Offset offset, int length, Color color) {
    final endOffset =
        offset.translate(length * _cellSize.width, _cellSize.height);

    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;

    canvas.drawRect(
      Rect.fromPoints(offset, endOffset),
      paint,
    );
  }

  /// Paints [line] to [canvas] at [offset]. The x offset of [offset] is usually
  /// 0, and the y offset is the top of the line.
  ///
  /// Consecutive cells sharing a background colour are drawn as one merged
  /// rect, and consecutive single-width cells sharing (foreground, background,
  /// flags) are drawn as one [Paragraph]. On a 200-column line that turns ~400
  /// draw calls into a handful. [paintLinePerCell] keeps the original
  /// one-call-per-cell loop, and
  /// `test/terminal/perf/pixel_equivalence_test.dart` asserts the two rasterise
  /// identically. See VENDORED.md.
  void paintLine(
    Canvas canvas,
    Offset offset,
    BufferLine line,
  ) {
    _paintBackgroundRuns(canvas, offset, line);
    _paintTextRuns(canvas, offset, line);
  }

  /// Pass 1 — one merged [Canvas.drawRect] per run of equal background colour.
  ///
  /// A per-cell rect is `cellWidth * widthScale + 1` wide and consecutive rects
  /// abut, so the union of a run spanning `span` cells is exactly
  /// `span * cellWidth + 1` wide, including the same 1 px right-hand spill.
  /// Terminal background colours are opaque, so merging cannot change a pixel.
  ///
  /// Written without closures on purpose: a closure that mutates the loop's
  /// run state boxes it on the heap, which is measurable over 10 000 cells.
  void _paintBackgroundRuns(Canvas canvas, Offset offset, BufferLine line) {
    Color? runColor;
    var runStart = 0;
    var runSpan = 0;

    for (var i = 0; i < line.length; i++) {
      // Read only the three words this pass needs, rather than filling a
      // CellData: the common case (no background at all) then costs two array
      // reads and two mask tests per cell.
      final background = line.getBackground(i);
      final flags = line.getAttributes(i);
      final charWidth = line.getContent(i) >> CellContent.widthShift;
      final widthScale = charWidth == 2 ? 2 : 1;

      final Color? color;
      if (flags & CellFlags.inverse != 0) {
        color = resolveForegroundColor(line.getForeground(i));
      } else if (background & CellColor.typeMask == CellColor.normal) {
        color = null;
      } else {
        color = resolveBackgroundColor(background);
      }

      if (runSpan > 0 && color == runColor) {
        runSpan += widthScale;
      } else {
        if (runSpan > 0 && runColor != null) {
          _fillBackgroundRun(canvas, offset, runStart, runSpan, runColor);
        }
        runColor = color;
        runStart = i;
        runSpan = color == null ? 0 : widthScale;
      }

      if (charWidth == 2) {
        i++;
      }
    }

    if (runSpan > 0 && runColor != null) {
      _fillBackgroundRun(canvas, offset, runStart, runSpan, runColor);
    }
  }

  @pragma('vm:prefer-inline')
  void _fillBackgroundRun(
    Canvas canvas,
    Offset offset,
    int startColumn,
    int span,
    Color color,
  ) {
    canvas.drawRect(
      Rect.fromLTWH(
        offset.dx + startColumn * _cellSize.width,
        offset.dy,
        span * _cellSize.width + 1,
        _cellSize.height,
      ),
      Paint()..color = color,
    );
  }

  /// Pass 2 — one [Canvas.drawParagraph] per run of cells sharing a style.
  ///
  /// Only cells with `charWidth == 1` and a non-zero code point may merge: a
  /// double-width glyph's font advance is not guaranteed to be exactly
  /// `2 * cellWidth`, a zero-width combining mark would compose with the
  /// previous glyph, and an empty cell must not become a space (a space under
  /// the underline flag paints, an empty cell does not). Everything else is
  /// drawn on its own, exactly as the per-cell painter does.
  ///
  /// A text run can never straddle a background run, because the run key
  /// includes `background` and `flags` — the only inputs to the background
  /// colour — so pass 1 and pass 2 agree on every boundary.
  void _paintTextRuns(Canvas canvas, Offset offset, BufferLine line) {
    final cellData = CellData.empty();
    // The first cell of the run in progress, kept so a one-cell run can go
    // straight to [paintCellForeground].
    final runCell = CellData.empty();
    final cellWidth = _cellSize.width;
    final runText = StringBuffer();

    var runStart = 0;
    var runLength = 0;

    for (var i = 0; i < line.length; i++) {
      line.getCellData(i, cellData);

      final charWidth = cellData.content >> CellContent.widthShift;

      if (charWidth != 1) {
        if (runLength > 0) {
          _flushTextRun(canvas, offset, runStart, runLength, runCell, runText);
          runLength = 0;
        }
        paintCellForeground(
          canvas,
          offset.translate(i * cellWidth, 0),
          cellData,
        );
        if (charWidth == 2) {
          i++;
        }
        continue;
      }

      if (cellData.content & CellContent.codepointMask == 0) {
        if (runLength > 0) {
          _flushTextRun(canvas, offset, runStart, runLength, runCell, runText);
          runLength = 0;
        }
        continue;
      }

      if (runLength > 0 &&
          cellData.foreground == runCell.foreground &&
          cellData.background == runCell.background &&
          cellData.flags == runCell.flags) {
        // Only materialise the run's text once it is actually a run — a
        // one-cell run never touches the StringBuffer at all.
        if (runLength == 1) {
          runText.writeCharCode(runCell.content & CellContent.codepointMask);
        }
        runText.writeCharCode(cellData.content & CellContent.codepointMask);
        runLength++;
        continue;
      }

      if (runLength > 0) {
        _flushTextRun(canvas, offset, runStart, runLength, runCell, runText);
      }
      runStart = i;
      runCell.foreground = cellData.foreground;
      runCell.background = cellData.background;
      runCell.flags = cellData.flags;
      runCell.content = cellData.content;
      runLength = 1;
    }

    if (runLength > 0) {
      _flushTextRun(canvas, offset, runStart, runLength, runCell, runText);
    }
  }

  @pragma('vm:prefer-inline')
  void _flushTextRun(
    Canvas canvas,
    Offset offset,
    int startColumn,
    int length,
    CellData runCell,
    StringBuffer runText,
  ) {
    final runOffset = offset.translate(startColumn * _cellSize.width, 0);
    if (length == 1) {
      // A one-cell run is what the per-cell painter already does best: its
      // int-keyed cache needs neither a String nor a key object, which matters
      // when every cell has its own style (10 000 runs a frame).
      paintCellForeground(canvas, runOffset, runCell);
      return;
    }
    _drawRun(
      canvas,
      runOffset,
      runText.toString(),
      runCell.foreground,
      runCell.background,
      runCell.flags,
    );
    runText.clear();
  }

  /// Lays out (or reuses) and draws one run of same-styled text.
  void _drawRun(
    Canvas canvas,
    Offset offset,
    String text,
    int foreground,
    int background,
    int flags,
  ) {
    // Flutter does not draw an underline below a space which is not between
    // other regular characters. As a workaround the regular space CodePoint
    // 0x20 is replaced with the CodePoint 0xA0. This is a non breaking space
    // and a underline can be drawn below it. A run has uniform flags, so the
    // substitution applies to the whole run at once.
    final runText = flags & CellFlags.underline != 0
        ? text.replaceAll('\u0020', '\u00A0')
        : text;

    final key = (runText, foreground, background, flags, _textScaler);

    var paragraph = _runCache[key];
    if (paragraph == null) {
      var color = flags & CellFlags.inverse == 0
          ? resolveForegroundColor(foreground)
          : resolveBackgroundColor(background);

      if (flags & CellFlags.faint != 0) {
        color = color.withOpacity(0.5);
      }

      final style = _textStyle.toTextStyle(
        color: color,
        bold: flags & CellFlags.bold != 0,
        italic: flags & CellFlags.italic != 0,
        underline: flags & CellFlags.underline != 0,
      );

      final builder = ParagraphBuilder(style.getParagraphStyle());
      builder.pushStyle(style.getTextStyle(textScaler: _textScaler));
      builder.addText(runText);

      paragraph = builder.build();
      paragraph.layout(const ParagraphConstraints(width: double.infinity));
      _runCache[key] = paragraph;
    }

    canvas.drawParagraph(paragraph, offset);
  }

  /// The original, unbatched per-cell paint loop, retained verbatim so the
  /// pixel-equivalence test can prove the batched [paintLine] draws exactly the
  /// same thing. Not used in production. See VENDORED.md.
  @visibleForTesting
  void paintLinePerCell(
    Canvas canvas,
    Offset offset,
    BufferLine line,
  ) {
    final cellData = CellData.empty();
    final cellWidth = _cellSize.width;

    for (var i = 0; i < line.length; i++) {
      line.getCellData(i, cellData);

      final charWidth = cellData.content >> CellContent.widthShift;
      final cellOffset = offset.translate(i * cellWidth, 0);

      paintCell(canvas, cellOffset, cellData);

      if (charWidth == 2) {
        i++;
      }
    }
  }

  @pragma('vm:prefer-inline')
  void paintCell(Canvas canvas, Offset offset, CellData cellData) {
    paintCellBackground(canvas, offset, cellData);
    paintCellForeground(canvas, offset, cellData);
  }

  /// Paints the character in the cell represented by [cellData] to [canvas] at
  /// [offset].
  @pragma('vm:prefer-inline')
  void paintCellForeground(Canvas canvas, Offset offset, CellData cellData) {
    final charCode = cellData.content & CellContent.codepointMask;
    if (charCode == 0) return;

    final cacheKey = cellData.getHash() ^ _textScaler.hashCode;
    var paragraph = _paragraphCache.getLayoutFromCache(cacheKey);

    if (paragraph == null) {
      final cellFlags = cellData.flags;

      var color = cellFlags & CellFlags.inverse == 0
          ? resolveForegroundColor(cellData.foreground)
          : resolveBackgroundColor(cellData.background);

      if (cellData.flags & CellFlags.faint != 0) {
        color = color.withOpacity(0.5);
      }

      final style = _textStyle.toTextStyle(
        color: color,
        bold: cellFlags & CellFlags.bold != 0,
        italic: cellFlags & CellFlags.italic != 0,
        underline: cellFlags & CellFlags.underline != 0,
      );

      // Flutter does not draw an underline below a space which is not between
      // other regular characters. As only single characters are drawn, this
      // will never produce an underline below a space in the terminal. As a
      // workaround the regular space CodePoint 0x20 is replaced with
      // the CodePoint 0xA0. This is a non breaking space and a underline can be
      // drawn below it.
      var char = String.fromCharCode(charCode);
      if (cellFlags & CellFlags.underline != 0 && charCode == 0x20) {
        char = String.fromCharCode(0xA0);
      }

      paragraph = _paragraphCache.performAndCacheLayout(
        char,
        style,
        _textScaler,
        cacheKey,
      );
    }

    canvas.drawParagraph(paragraph, offset);
  }

  /// Paints the background of a cell represented by [cellData] to [canvas] at
  /// [offset].
  @pragma('vm:prefer-inline')
  void paintCellBackground(Canvas canvas, Offset offset, CellData cellData) {
    late Color color;
    final colorType = cellData.background & CellColor.typeMask;

    if (cellData.flags & CellFlags.inverse != 0) {
      color = resolveForegroundColor(cellData.foreground);
    } else if (colorType == CellColor.normal) {
      return;
    } else {
      color = resolveBackgroundColor(cellData.background);
    }

    final paint = Paint()..color = color;
    final doubleWidth = cellData.content >> CellContent.widthShift == 2;
    final widthScale = doubleWidth ? 2 : 1;
    final size = Size(_cellSize.width * widthScale + 1, _cellSize.height);
    canvas.drawRect(offset & size, paint);
  }

  /// Get the effective foreground color for a cell from information encoded in
  /// [cellColor].
  @pragma('vm:prefer-inline')
  Color resolveForegroundColor(int cellColor) {
    final colorType = cellColor & CellColor.typeMask;
    final colorValue = cellColor & CellColor.valueMask;

    switch (colorType) {
      case CellColor.normal:
        return _theme.foreground;
      case CellColor.named:
      case CellColor.palette:
        return _colorPalette[colorValue];
      case CellColor.rgb:
      default:
        return Color(colorValue | 0xFF000000);
    }
  }

  /// Get the effective background color for a cell from information encoded in
  /// [cellColor].
  @pragma('vm:prefer-inline')
  Color resolveBackgroundColor(int cellColor) {
    final colorType = cellColor & CellColor.typeMask;
    final colorValue = cellColor & CellColor.valueMask;

    switch (colorType) {
      case CellColor.normal:
        return _theme.background;
      case CellColor.named:
      case CellColor.palette:
        return _colorPalette[colorValue];
      case CellColor.rgb:
      default:
        return Color(colorValue | 0xFF000000);
    }
  }
}

/// Structural key for [TerminalPainter]'s run paragraph cache: the run's text
/// plus everything that affects how it is styled.
typedef _RunKey = (String, int, int, int, TextScaler);
