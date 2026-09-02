import 'dart:ui';

import 'package:flutter/painting.dart';
import 'package:xterm/xterm.dart';

import 'counting_canvas.dart';

/// A painter configured like the one `TerminalPanel` uses in the app.
TerminalPainter makePainter() => TerminalPainter(
  theme: TerminalThemes.defaultTheme,
  textStyle: const TerminalStyle(fontSize: 13, fontFamily: 'monospace'),
  textScaler: TextScaler.noScaling,
);

/// Paints every visible line of [terminal] once onto [canvas].
///
/// With [perCell] the original one-draw-call-per-cell loop is used; otherwise
/// the run-batched [TerminalPainter.paintLine].
void paintViewport(
  TerminalPainter painter,
  Canvas canvas,
  Terminal terminal, {
  bool perCell = false,
}) {
  painter.beginFrame();
  final lines = terminal.buffer.lines;
  final height = painter.cellSize.height;
  final count = terminal.viewHeight < lines.length
      ? terminal.viewHeight
      : lines.length;
  for (var i = 0; i < count; i++) {
    final offset = Offset(0, i * height);
    if (perCell) {
      painter.paintLinePerCell(canvas, offset, lines[i]);
    } else {
      painter.paintLine(canvas, offset, lines[i]);
    }
  }
}

/// The per-cell painter, drawing in the batched painter's **order**: every
/// background on the line first, then every glyph.
///
/// This is the reference the batched painter is actually held to, and the
/// distinction is not a technicality. `paintLinePerCell` interleaves — cell 0's
/// background, cell 0's glyph, cell 1's background, cell 1's glyph — so each
/// cell's background rect paints over whatever the *previous* glyph spilled
/// past its cell. The batched painter cannot interleave: merging a run of
/// backgrounds into one rect is the whole point of it, and that rect has to go
/// down before the text.
///
/// So wherever a glyph overhangs its cell to the right, the two orders disagree
/// by design, and the batched one is the better answer — a terminal should not
/// chop a glyph because the next cell happens to have a background colour.
/// Which glyphs overhang is a property of the *font*, which is why comparing
/// against the interleaved order passed on Windows and failed on macOS: 660
/// bytes of an 8.3 MB frame, every one of them a one-pixel-wide sliver down the
/// left edge of a cell, none of them a batching bug.
void paintViewportPerCellTwoPass(
  TerminalPainter painter,
  Canvas canvas,
  Terminal terminal,
) {
  final lines = terminal.buffer.lines;
  final width = painter.cellSize.width;
  final height = painter.cellSize.height;
  final count = terminal.viewHeight < lines.length
      ? terminal.viewHeight
      : lines.length;
  final cell = CellData.empty();
  for (var i = 0; i < count; i++) {
    final line = lines[i];
    final offset = Offset(0, i * height);
    for (var c = 0; c < line.length; c++) {
      line.getCellData(c, cell);
      painter.paintCellBackground(canvas, offset.translate(c * width, 0), cell);
      if (cell.content >> CellContent.widthShift == 2) c++;
    }
    for (var c = 0; c < line.length; c++) {
      line.getCellData(c, cell);
      painter.paintCellForeground(canvas, offset.translate(c * width, 0), cell);
      if (cell.content >> CellContent.widthShift == 2) c++;
    }
  }
}

/// Exact number of draw calls needed to paint one full viewport frame.
///
/// [settled] is the number the per-corpus budgets are stated against: the
/// painter meters how much paragraph layout it will do in one frame
/// (`TerminalPainter.beginFrame`), so a screen that has just appeared is drawn
/// partly cell by cell and reaches its batched draw-call count over the next
/// few frames instead of on the first one. Repainting until no frame lays out
/// anything new is what "the terminal is sitting there showing this" means, and
/// it is the state a draw-call budget is about.
///
/// Pass `settled: false` for the first frame after the content appeared — the
/// transient. It is bounded too, by `paint_layout_cost_test.dart`, but by the
/// per-cell painter's count rather than by the batched budget.
int countDrawOps(
  Terminal terminal, {
  bool perCell = false,
  bool settled = true,
}) {
  final painter = makePainter();
  if (settled) {
    // 64 frames is far more than any corpus needs (the worst, colorizedLs at
    // 878 runs, converges in 19), and the loop exits as soon as a frame lays
    // nothing out, so this costs nothing for the corpora that settle at once.
    for (var frame = 0; frame < 64; frame++) {
      painter.resetPaintCounters();
      final warm = PictureRecorder();
      paintViewport(painter, Canvas(warm), terminal, perCell: perCell);
      warm.endRecording().dispose();
      if (painter.runParagraphsLaidOut == 0) break;
    }
  }
  final recorder = PictureRecorder();
  final canvas = CountingCanvas(Canvas(recorder));
  paintViewport(painter, canvas, terminal, perCell: perCell);
  recorder.endRecording().dispose();
  return canvas.drawOps;
}

/// Median and p95 wall time to paint one full viewport frame, over [frames]
/// samples taken after a warm-up (so the paragraph cache is hot and we measure
/// steady state, not first-layout cost).
({Duration median, Duration p95}) benchPaint(
  Terminal terminal, {
  int frames = 200,
  bool perCell = false,
}) {
  final painter = makePainter();

  for (var i = 0; i < 20; i++) {
    final recorder = PictureRecorder();
    paintViewport(painter, Canvas(recorder), terminal, perCell: perCell);
    recorder.endRecording().dispose();
  }

  final samples = <int>[];
  for (var i = 0; i < frames; i++) {
    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    final stopwatch = Stopwatch()..start();
    paintViewport(painter, canvas, terminal, perCell: perCell);
    stopwatch.stop();
    samples.add(stopwatch.elapsedMicroseconds);
    recorder.endRecording().dispose();
  }
  samples.sort();
  return (
    median: Duration(microseconds: samples[samples.length ~/ 2]),
    p95: Duration(microseconds: samples[(samples.length * 95) ~/ 100]),
  );
}
