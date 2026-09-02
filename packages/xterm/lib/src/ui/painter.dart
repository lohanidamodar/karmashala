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

  /// How many *new* run paragraphs [paintLine] may lay out in one frame before
  /// it stops laying out and paints the rest of that frame's misses cell by
  /// cell instead. See [beginFrame] for why there is a budget at all.
  ///
  /// 48 is picked from the cost of a miss, not from taste. Instrumenting the
  /// miss branch (`tool/benchmark/paint_stream_bench.dart`) gives
  /// ~11 us of fixed `ParagraphBuilder` + `build` + `layout` overhead per
  /// paragraph plus ~0.19 us per character, so a 200-column run costs ~49 us
  /// and a ~11-column `ls` entry ~23 us. 48 long runs is therefore ~2.4 ms —
  /// about a seventh of the 16.67 ms frame, small enough to leave room for the
  /// rest of the app's paint, and large enough that a full 200x50 viewport of
  /// one-run-per-line output (the plain-log case, 50 runs) converges to fully
  /// batched in two frames.
  static const maxRunLayoutsPerFrame = 48;

  /// Remaining layouts in the current frame. Starts full so that a
  /// [TerminalPainter] driven directly — by a test, or by anything that does
  /// not call [beginFrame] — still batches its first frame.
  int _runLayoutBudget = maxRunLayoutsPerFrame;

  /// Number of run paragraphs laid out since [resetPaintCounters].
  ///
  /// Exposed because this is the quantity the painter's cost is made of: at
  /// ~11-49 us apiece it is 90-93% of the time [paintLine] spends on a frame
  /// whose content changed. `test/terminal/perf/paint_layout_cost_test.dart`
  /// asserts on it rather than on wall clock.
  @visibleForTesting
  int runParagraphsLaidOut = 0;

  /// Number of runs painted cell by cell because the frame's layout budget was
  /// already spent. Counted so a test can tell "the budget held" apart from
  /// "there was nothing to lay out".
  @visibleForTesting
  int runsDeferredToCells = 0;

  /// Number of *cell* paragraphs laid out since [resetPaintCounters].
  ///
  /// The claim that makes the fallback in [_drawRun] worth taking is that
  /// [_paragraphCache] hits where [_runCache] cannot, because its key is
  /// (code point, colours, flags) rather than a whole run's text — a few
  /// hundred live entries for real output against one per distinct run.
  /// `paint_layout_cost_test.dart` asserts on this counter so the claim is
  /// pinned by a number and not by the comment above it.
  @visibleForTesting
  int cellParagraphsLaidOut = 0;

  @visibleForTesting
  void resetPaintCounters() {
    runParagraphsLaidOut = 0;
    runsDeferredToCells = 0;
    cellParagraphsLaidOut = 0;
  }

  /// Called once per frame, before the frame's first [paintLine].
  ///
  /// A terminal's paint cost is dominated by laying out paragraphs for text it
  /// has never seen before, and the frames where that happens are exactly the
  /// frames that are already busy: a screenful of new output arrives, every run
  /// on every line misses [_runCache], and the painter lays out one paragraph
  /// per run before it may draw anything. Measured on a full 200x50 viewport of
  /// freshly arrived `ls --color`-shaped output (`stream colour 50 lines/frame`
  /// in `tool/benchmark/paint_stream_bench.dart`): 686 layouts per frame,
  /// 15.6 ms of the frame's 16.7 ms inside the miss branch, zero cache hits.
  /// That is the whole frame budget spent on text that will have scrolled away
  /// in a second.
  ///
  /// So the budget is refilled here rather than being unlimited. Runs past the
  /// budget are painted cell by cell out of [_paragraphCache], whose key is
  /// (code point, colours, flags) rather than the run's text — a key space of a
  /// few hundred entries for real output, so it hits essentially always: the
  /// same colour-streaming frame records 19 880 per-cell hits and *zero*
  /// per-cell layouts. Painting a run out of that cache costs ~0.17 us per
  /// cell, which beats laying the run out at any run length.
  ///
  /// What the budget costs is draw calls, and only until the screen settles:
  /// a run that misses today is laid out on a later frame and batched from then
  /// on, so a screen that stops changing converges to exactly the same drawing
  /// the unbudgeted painter did. It is the transient that is bounded, and
  /// `tool/benchmark/raster_cost_bench.dart` prices it: rasterising a viewport
  /// cell by cell instead of by runs costs 1.9-3.1 ms more, on the raster
  /// thread, against 13.7 ms saved on the UI thread. Each visible pane has its
  /// own painter and so its own budget, which is the intended shape — four
  /// split panes all filling with new output at once cost 4 x 2.4 ms of layout
  /// rather than 4 x 15.6 ms.
  ///
  /// Ruled out on the way here, so nobody re-measures them:
  ///
  /// * **Hoisting the style objects out of the miss branch.** `toTextStyle` +
  ///   `getParagraphStyle` + `getTextStyle` (which copies a 14-entry font
  ///   fallback list) looks like the allocation to kill, but it is ~1.5 us of a
  ///   ~16 us miss. Worth ~10%, not the 5x.
  /// * **Growing or re-keying [_runCache].** The hit rate on a streaming
  ///   viewport is not low, it is *zero* — the key is the run's text and the
  ///   text is new. No cache size and no cheaper key changes that.
  /// * **Dropping run batching and always painting per cell.** That is the 1.9
  ///   to 3.1 ms of extra raster work above, paid on *every* frame including
  ///   the ones where nothing changed, and it is what the batching was
  ///   introduced to remove.
  void beginFrame() {
    _runLayoutBudget = maxRunLayoutsPerFrame;
  }

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

  /// FORKED: [underline] draws a rule along the bottom of the cells instead of
  /// filling them, so a hovered link is marked the way a browser marks one and
  /// the text under it stays exactly as legible. Everything else, including the
  /// filled path, is upstream's. See VENDORED.md.
  @pragma('vm:prefer-inline')
  void paintHighlight(
    Canvas canvas,
    Offset offset,
    int length,
    Color color, {
    bool underline = false,
  }) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;

    if (underline) {
      canvas.drawRect(
        Rect.fromLTWH(
          offset.dx,
          offset.dy + _cellSize.height - 2,
          length * _cellSize.width,
          1,
        ),
        paint,
      );
      return;
    }

    final endOffset =
        offset.translate(length * _cellSize.width, _cellSize.height);

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
          _flushTextRun(
            canvas,
            offset,
            line,
            runStart,
            runLength,
            runCell,
            runText,
          );
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
          _flushTextRun(
            canvas,
            offset,
            line,
            runStart,
            runLength,
            runCell,
            runText,
          );
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
        _flushTextRun(
          canvas,
          offset,
          line,
          runStart,
          runLength,
          runCell,
          runText,
        );
      }
      runStart = i;
      runCell.foreground = cellData.foreground;
      runCell.background = cellData.background;
      runCell.flags = cellData.flags;
      runCell.content = cellData.content;
      runLength = 1;
    }

    if (runLength > 0) {
      _flushTextRun(
        canvas,
        offset,
        line,
        runStart,
        runLength,
        runCell,
        runText,
      );
    }
  }

  @pragma('vm:prefer-inline')
  void _flushTextRun(
    Canvas canvas,
    Offset offset,
    BufferLine line,
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
      offset,
      runOffset,
      line,
      startColumn,
      length,
      runText.toString(),
      runCell.foreground,
      runCell.background,
      runCell.flags,
    );
    runText.clear();
  }

  /// Draws one run of same-styled text: reusing its [Paragraph] if one is
  /// cached, laying one out if this frame can still afford to, and otherwise
  /// painting the run cell by cell.
  ///
  /// The three-way choice, rather than upstream's "look up, else lay out", is
  /// the point of the change. A cache keyed on the run's *text* cannot hit on
  /// text the terminal has never printed, and printing text it has never
  /// printed is what a terminal does. Measured over 40 frames of a 200x50
  /// viewport being filled with fresh `ls --color`-shaped lines
  /// (`stream colour 50 lines/frame` in `tool/benchmark/paint_stream_bench.dart`):
  /// 27 440 layouts, **zero** hits, 15.6 ms of each 16.7 ms frame spent inside
  /// this method. The same corpus held still repaints in 462 us. The cache was
  /// never broken — it is irrelevant on exactly the frames that drop.
  ///
  /// See [beginFrame] for the budget, and [_paintRunPerCell] for why the third
  /// branch is both cheap and pixel-exact.
  void _drawRun(
    Canvas canvas,
    Offset lineOffset,
    Offset runOffset,
    BufferLine line,
    int startColumn,
    int length,
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

    final cached = _runCache[key];
    if (cached != null) {
      canvas.drawParagraph(cached, runOffset);
      return;
    }

    if (_runLayoutBudget <= 0) {
      runsDeferredToCells++;
      _paintRunPerCell(canvas, lineOffset, line, startColumn, length);
      return;
    }
    _runLayoutBudget--;
    runParagraphsLaidOut++;

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

    final paragraph = builder.build();
    paragraph.layout(const ParagraphConstraints(width: double.infinity));
    _runCache[key] = paragraph;

    canvas.drawParagraph(paragraph, runOffset);
  }

  /// Paints `[startColumn, startColumn + length)` of [line] one cell at a time,
  /// which is what [_drawRun] falls back to when the frame's layout budget is
  /// spent.
  ///
  /// This is not an approximation of the batched path, it is the path the
  /// batched one is *held to*: `test/terminal/perf/pixel_equivalence_test.dart`
  /// rasterises whole viewports both ways and requires the bytes to match, so a
  /// run drawn cell by cell after its merged background rect is already down is
  /// the same picture as the same run drawn as one paragraph. Colour, faint,
  /// bold, italic, inverse and the underline-on-space substitution are all
  /// re-derived inside [paintCellForeground] from the same four cell words, so
  /// nothing about the style is duplicated here and nothing can drift out of
  /// step with the run path.
  ///
  /// Only cells a run was allowed to contain reach this loop — single width,
  /// non-zero code point — so unlike [paintLinePerCell] it needs no
  /// double-width skipping and can never paint a trailing half-cell.
  void _paintRunPerCell(
    Canvas canvas,
    Offset lineOffset,
    BufferLine line,
    int startColumn,
    int length,
  ) {
    final cellWidth = _cellSize.width;
    final cell = _fallbackCell;
    for (var i = 0; i < length; i++) {
      final column = startColumn + i;
      line.getCellData(column, cell);
      paintCellForeground(
        canvas,
        lineOffset.translate(column * cellWidth, 0),
        cell,
      );
    }
  }

  /// Scratch cell for [_paintRunPerCell], held on the painter rather than
  /// allocated per call: the fallback is the *busy* frame's path, and on a
  /// 200x50 viewport of unseen output it would otherwise allocate one
  /// [CellData] per run, hundreds a frame, exactly when the frame has no time
  /// to spare. The painter is never re-entered, so one scratch cell is enough.
  final _fallbackCell = CellData.empty();

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

      cellParagraphsLaidOut++;
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
