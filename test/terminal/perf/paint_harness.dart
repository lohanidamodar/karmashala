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

/// Exact number of draw calls needed to paint one full viewport frame.
int countDrawOps(Terminal terminal, {bool perCell = false}) {
  final painter = makePainter();
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
