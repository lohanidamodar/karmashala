import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

import '../../test/terminal/perf/corpora.dart';
import '../../test/terminal/perf/paint_harness.dart';

/// Benchmark — NOT part of `flutter test`. Run on demand:
///
///   flutter test tool/benchmark/paint_stream_bench.dart
///
/// `paint_bench.dart` beside this one measures a *static* frame repainted 200
/// times, so its numbers are the steady state with a fully warm paragraph
/// cache. This one measures the cases where the content under the painter
/// changes between frames, which is what a terminal actually does.

const _columns = kPerfColumns;
const _rows = kPerfRows;

// ignore_for_file: invalid_use_of_visible_for_testing_member

String _counters(TerminalPainter p) =>
    'layouts=${p.runParagraphsLaidOut} deferred=${p.runsDeferredToCells}';

/// Paints the *last* [_rows] lines of the buffer, the way `RenderTerminal`
/// paints a viewport pinned to the bottom.
void _paintBottom(TerminalPainter painter, Canvas canvas, Terminal terminal) {
  painter.beginFrame();
  final lines = terminal.buffer.lines;
  final height = painter.cellSize.height;
  final first = lines.length - _rows < 0 ? 0 : lines.length - _rows;
  for (var i = first; i < lines.length; i++) {
    painter.paintLine(canvas, Offset(0, (i - first) * height), lines[i]);
  }
}

void _paintWindow(
  TerminalPainter painter,
  Canvas canvas,
  Terminal terminal,
  int first,
) {
  painter.beginFrame();
  final lines = terminal.buffer.lines;
  final height = painter.cellSize.height;
  for (var i = first; i < first + _rows && i < lines.length; i++) {
    painter.paintLine(canvas, Offset(0, (i - first) * height), lines[i]);
  }
}

({int median, int p95}) _stats(List<int> samples) {
  samples.sort();
  return (
    median: samples[samples.length ~/ 2],
    p95: samples[(samples.length * 95) ~/ 100],
  );
}

String _logLine(int n) =>
    '[${(n * 137) % 100000}] compiling package:karmashala/src/features/'
            'terminal/data/terminal_instance.dart unit $n'
        .padRight(_columns)
        .substring(0, _columns);

/// One line of `ls --color`-shaped output: many short coloured runs.
String _colorLine(int n) {
  const sgr = <String>[
    '\x1b[0m',
    '\x1b[1;34m',
    '\x1b[32m',
    '\x1b[1;36m',
    '\x1b[33m',
    '\x1b[35m',
    '\x1b[1;31m',
  ];
  final buffer = StringBuffer();
  var width = 0;
  var i = 0;
  while (width < _columns) {
    final name = 'entry_${n}_$i';
    buffer.write(sgr[(n + i) % sgr.length]);
    final take = width + name.length > _columns
        ? _columns - width
        : name.length;
    buffer.write(name.substring(0, take));
    width += take;
    if (width < _columns) {
      buffer.write('\x1b[0m ');
      width += 1;
    }
    i++;
  }
  buffer.write('\x1b[0m');
  return buffer.toString();
}

void main() {
  test('cold frame: first paint of a viewport, empty cache', () {
    for (final corpus in PerfCorpus.values) {
      final terminal = buildTerminal(corpus);
      final samples = <int>[];
      TerminalPainter? last;
      for (var i = 0; i < 20; i++) {
        // A fresh painter per sample: nothing cached, exactly like the first
        // frame after a theme change, a font-size change or a resize.
        final painter = makePainter()..resetPaintCounters();
        final recorder = PictureRecorder();
        final canvas = Canvas(recorder);
        final sw = Stopwatch()..start();
        paintViewport(painter, canvas, terminal);
        sw.stop();
        samples.add(sw.elapsedMicroseconds);
        last = painter;
        recorder.endRecording().dispose();
      }
      final s = _stats(samples);
      // ignore: avoid_print
      print(
        'cold $corpus: median=${s.median}us p95=${s.p95}us '
        '${_counters(last!)}',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('streaming: one new line per frame, viewport pinned to bottom', () {
    final terminal = Terminal(maxLines: 4000);
    terminal.resize(_columns, _rows);
    final painter = makePainter();
    for (var i = 0; i < _rows; i++) {
      terminal.write('${_logLine(i)}\r\n');
    }
    for (var i = 0; i < 20; i++) {
      final r = PictureRecorder();
      _paintBottom(painter, Canvas(r), terminal);
      r.endRecording().dispose();
    }
    painter.resetPaintCounters();
    final samples = <int>[];
    for (var frame = 0; frame < 200; frame++) {
      terminal.write('${_logLine(1000 + frame)}\r\n');
      final r = PictureRecorder();
      final canvas = Canvas(r);
      final sw = Stopwatch()..start();
      _paintBottom(painter, canvas, terminal);
      sw.stop();
      samples.add(sw.elapsedMicroseconds);
      r.endRecording().dispose();
    }
    final s = _stats(samples);
    // ignore: avoid_print
    print(
      'stream plain 1 line/frame: median=${s.median}us p95=${s.p95}us '
      '${_counters(painter)}',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('streaming burst: a full screen of new plain lines per frame', () {
    final terminal = Terminal(maxLines: 4000);
    terminal.resize(_columns, _rows);
    final painter = makePainter();
    for (var i = 0; i < _rows; i++) {
      terminal.write('${_logLine(i)}\r\n');
    }
    for (var i = 0; i < 5; i++) {
      final r = PictureRecorder();
      _paintBottom(painter, Canvas(r), terminal);
      r.endRecording().dispose();
    }
    painter.resetPaintCounters();
    final samples = <int>[];
    for (var frame = 0; frame < 60; frame++) {
      for (var i = 0; i < _rows; i++) {
        terminal.write('${_logLine(10000 + frame * _rows + i)}\r\n');
      }
      final r = PictureRecorder();
      final canvas = Canvas(r);
      final sw = Stopwatch()..start();
      _paintBottom(painter, canvas, terminal);
      sw.stop();
      samples.add(sw.elapsedMicroseconds);
      r.endRecording().dispose();
    }
    final s = _stats(samples);
    // ignore: avoid_print
    print(
      'stream plain 50 lines/frame: median=${s.median}us p95=${s.p95}us '
      '${_counters(painter)}',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('streaming burst: a full screen of new COLOURED lines per frame', () {
    final terminal = Terminal(maxLines: 4000);
    terminal.resize(_columns, _rows);
    final painter = makePainter();
    for (var i = 0; i < _rows; i++) {
      terminal.write('${_colorLine(i)}\r\n');
    }
    for (var i = 0; i < 5; i++) {
      final r = PictureRecorder();
      _paintBottom(painter, Canvas(r), terminal);
      r.endRecording().dispose();
    }
    painter.resetPaintCounters();
    final samples = <int>[];
    for (var frame = 0; frame < 40; frame++) {
      for (var i = 0; i < _rows; i++) {
        terminal.write('${_colorLine(10000 + frame * _rows + i)}\r\n');
      }
      final r = PictureRecorder();
      final canvas = Canvas(r);
      final sw = Stopwatch()..start();
      _paintBottom(painter, canvas, terminal);
      sw.stop();
      samples.add(sw.elapsedMicroseconds);
      r.endRecording().dispose();
    }
    final s = _stats(samples);
    // ignore: avoid_print
    print(
      'stream colour 50 lines/frame: median=${s.median}us p95=${s.p95}us '
      '${_counters(painter)}',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('fling scroll: 12 lines/frame through a 3000-line log', () {
    final terminal = Terminal(maxLines: 4000);
    terminal.resize(_columns, _rows);
    for (var i = 0; i < 3000; i++) {
      terminal.write('${_logLine(i)}\r\n');
    }
    final painter = makePainter();
    for (var i = 0; i < 5; i++) {
      final r = PictureRecorder();
      _paintWindow(painter, Canvas(r), terminal, 0);
      r.endRecording().dispose();
    }
    painter.resetPaintCounters();
    final samples = <int>[];
    for (var frame = 0; frame < 200; frame++) {
      final r = PictureRecorder();
      final canvas = Canvas(r);
      final sw = Stopwatch()..start();
      _paintWindow(painter, canvas, terminal, frame * 12);
      sw.stop();
      samples.add(sw.elapsedMicroseconds);
      r.endRecording().dispose();
    }
    final s = _stats(samples);
    // ignore: avoid_print
    print(
      'fling 12 lines/frame: median=${s.median}us p95=${s.p95}us '
      '${_counters(painter)}',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('animated TUI: every line redrawn with a changing counter', () {
    final terminal = Terminal(maxLines: _rows);
    terminal.resize(_columns, _rows);
    final painter = makePainter();
    for (var i = 0; i < 5; i++) {
      final r = PictureRecorder();
      _paintBottom(painter, Canvas(r), terminal);
      r.endRecording().dispose();
    }
    painter.resetPaintCounters();
    final samples = <int>[];
    for (var frame = 0; frame < 120; frame++) {
      final buffer = StringBuffer('\x1b[H');
      for (var row = 0; row < _rows; row++) {
        buffer
          ..write(
            'task $row  cpu ${(frame * 7 + row) % 100}.${frame % 10}%  '
                    'mem ${(frame * 3 + row) % 999}MB  elapsed ${frame}s'
                .padRight(_columns)
                .substring(0, _columns),
          )
          ..write('\r\n');
      }
      terminal.write(buffer.toString());
      final r = PictureRecorder();
      final canvas = Canvas(r);
      final sw = Stopwatch()..start();
      _paintBottom(painter, canvas, terminal);
      sw.stop();
      samples.add(sw.elapsedMicroseconds);
      r.endRecording().dispose();
    }
    final s = _stats(samples);
    // ignore: avoid_print
    print(
      'animated TUI: median=${s.median}us p95=${s.p95}us '
      '${_counters(painter)}',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
}
