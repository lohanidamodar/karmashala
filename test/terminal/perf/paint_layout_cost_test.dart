import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

import 'corpora.dart';
import 'paint_harness.dart';

/// What **painting a frame of output nobody has seen before** costs, as a gate
/// rather than as a benchmark.
///
/// Same house rule as `ingest_throughput_cost_test.dart` and
/// `terminal_search_cost_test.dart`: counted, not timed, because a stopwatch
/// assertion over a few milliseconds fails when the machine is busy and teaches
/// everyone to re-run it instead of reading it. `draw_ops_test.dart` beside
/// this one counts *draw calls*; this one counts the other half of a frame,
/// which turned out to be the expensive half.
///
/// The unit is **run paragraphs laid out**, because that is what the painter's
/// time is made of. Instrumenting the miss branch of `TerminalPainter._drawRun`
/// (`tool/benchmark/paint_stream_bench.dart`, counters on the painter) over a
/// 200x50 viewport being filled with fresh `ls --color`-shaped lines gave:
///
/// ```
/// stream colour 50 lines/frame: median=16705us p95=19098us
///   runLayouts=27440 runHits=0 runLayoutUs=624730
/// ```
///
/// 686 layouts a frame, **zero** cache hits, and 15.6 ms of each 16.7 ms frame
/// inside `ParagraphBuilder`/`build`/`layout` — 93% of the paint. The same
/// content held still repaints in 462 us. So the run cache was never the
/// problem; it simply cannot hit on text a terminal is printing for the first
/// time, which is most of the text a terminal prints.
///
/// A paragraph costs ~11 us of fixed overhead plus ~0.19 us per character, so
/// the fix is to stop laying out an unbounded number of them per frame:
/// `TerminalPainter.beginFrame` refills a budget of
/// [TerminalPainter.maxRunLayoutsPerFrame], and runs past it are painted out of
/// the per-cell paragraph cache instead — whose key is (code point, colours,
/// flags), so it hits essentially always. The same benchmark after the change:
///
/// ```
/// stream colour 50 lines/frame: median=2968us p95=3730us
///   layouts=1920 deferred=25520
/// ```
///
/// The assertions below pin every part of that: the cap holds under fresh
/// output, the fallback does not quietly pay layout cost of its own, and a
/// screen that stops changing still converges to fully batched drawing.
void main() {
  group('a screenful of never-before-seen output', () {
    test('lays out no more than the frame budget, however many runs it has', () {
      final stream = _StreamedViewport(colored: true);
      final measured = stream.run(frames: 20);

      // Guard the guard: if the corpus stopped producing far more runs per
      // frame than the budget allows, the cap below would pass without ever
      // being reached and this file would assert nothing.
      expect(
        measured.runsPerFrame,
        greaterThan(4 * TerminalPainter.maxRunLayoutsPerFrame),
        reason:
            'this test only means something while a frame carries many more '
            'style runs than the painter may lay out; it carries '
            '${measured.runsPerFrame}',
      );

      expect(
        measured.worstFrameLayouts,
        lessThanOrEqualTo(TerminalPainter.maxRunLayoutsPerFrame),
        reason:
            'a frame laid out ${measured.worstFrameLayouts} run paragraphs at '
            '~11-49 us each. Unbudgeted this corpus lays out '
            '${measured.runsPerFrame} a frame, which measured 15.6 ms of a '
            '16.7 ms frame.',
      );
    });

    test('does not pay per-cell layout instead of per-run layout', () {
      // The fallback is only cheap because the per-cell cache hits. If it
      // started missing, this change would have moved the cost rather than
      // removed it — the same number of paragraphs, one per cell instead of one
      // per run, which is how the terminal painted before it batched at all.
      final stream = _StreamedViewport(colored: true);
      final measured = stream.run(frames: 20);

      // 20 frames x 50 lines x 200 columns = 200 000 cells painted. The
      // distinct (code point, colour, flags) triples in this corpus are the
      // ~40 characters `entry_<n>_<n>` can contain against 7 SGR states, so a
      // few hundred layouts covers every cell that will ever be drawn and
      // every frame after the first few pays nothing at all.
      expect(
        measured.cellLayouts,
        lessThan(2000),
        reason:
            '${measured.cellLayouts} cell paragraphs for '
            '${measured.cellsPainted} cells painted — the per-cell cache is '
            'missing, so the fallback is not free and the budget is only '
            'moving the cost',
      );
      expect(
        measured.deferredRuns,
        greaterThan(0),
        reason: 'the fallback never ran, so this measured nothing',
      );
    });
  });

  group('a screen that stops changing', () {
    for (final corpus in PerfCorpus.values) {
      test('$corpus converges to fully batched drawing', () {
        final terminal = buildTerminal(corpus);
        final painter = makePainter();

        var frames = 0;
        var totalLayouts = 0;
        while (frames < 64) {
          painter.resetPaintCounters();
          final recorder = PictureRecorder();
          paintViewport(painter, Canvas(recorder), terminal);
          recorder.endRecording().dispose();
          frames++;
          totalLayouts += painter.runParagraphsLaidOut;
          if (painter.runParagraphsLaidOut == 0) break;
        }

        // ignore: avoid_print
        print(
          '$corpus settled after $frames frames, $totalLayouts run layouts',
        );

        expect(
          painter.runParagraphsLaidOut,
          0,
          reason:
              '$corpus never stopped laying paragraphs out. A static screen '
              'must reach a steady state, or the budget has turned a one-off '
              'cost into a per-frame one',
        );
        expect(
          painter.runsDeferredToCells,
          0,
          reason:
              '$corpus settled but is still drawing '
              '${painter.runsDeferredToCells} runs cell by cell. The batching '
              'draw_ops_test.dart budgets for is meant to be fully restored '
              'once nothing is changing',
        );
        // A settled screen may not need more than one frame per budget's worth
        // of runs to get there; anything beyond that means runs are being laid
        // out repeatedly, which is thrash rather than convergence.
        expect(
          frames,
          lessThanOrEqualTo(
            2 +
                (totalLayouts + TerminalPainter.maxRunLayoutsPerFrame - 1) ~/
                    TerminalPainter.maxRunLayoutsPerFrame,
          ),
          reason:
              '$corpus took $frames frames to lay out $totalLayouts runs; at '
              '${TerminalPainter.maxRunLayoutsPerFrame} per frame it should '
              'need no more than '
              '${2 + totalLayouts ~/ TerminalPainter.maxRunLayoutsPerFrame}',
        );
      });
    }
  });

  testWidgets('RenderTerminal refills the budget once per frame', (
    tester,
  ) async {
    // The painter's budget is refilled by its caller, and every other test in
    // this directory goes through `paintViewport`, which refills it itself. So
    // deleting the call from `RenderTerminal._paint` would leave the whole
    // suite green while the app painted its first screenful of output and then
    // fell back to per-cell drawing forever.
    final terminal = Terminal(maxLines: 200);
    final controller = TerminalController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1200, 700)),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: TerminalView(
            terminal,
            controller: controller,
            autofocus: false,
          ),
        ),
      ),
    );

    final render = tester.renderObject<RenderTerminal>(
      find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_TerminalView',
      ),
    );

    // Two frames of content that has never been painted, each far wider than
    // the budget. If the budget is refilled per frame both frames lay out; if
    // it is not, the second frame lays out nothing at all.
    final laidOut = <int>[];
    for (var frame = 0; frame < 2; frame++) {
      for (var row = 0; row < 40; row++) {
        terminal.write('${_coloredLine(frame * 1000 + row, 120)}\r\n');
      }
      render.painter.resetPaintCounters();
      await tester.pump();
      laidOut.add(render.painter.runParagraphsLaidOut);
    }

    expect(
      laidOut.first,
      greaterThan(0),
      reason: 'the first frame painted nothing new, so this proves nothing',
    );
    expect(
      laidOut.last,
      greaterThan(0),
      reason:
          'the second frame laid out $laidOut — the per-frame layout budget '
          'was never refilled, so RenderTerminal.paint is not calling '
          'TerminalPainter.beginFrame',
    );
  });
}

/// One line of `ls --color`-shaped output: many short runs, each its own colour,
/// and no two lines alike.
String _coloredLine(int seed, int columns) {
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
  while (width < columns) {
    final name = 'entry_${seed}_$i';
    buffer.write(sgr[(seed + i) % sgr.length]);
    final take = width + name.length > columns ? columns - width : name.length;
    buffer.write(name.substring(0, take));
    width += take;
    if (width < columns) {
      buffer
        ..write('\x1b[0m')
        ..write(' ');
      width += 1;
    }
    i++;
  }
  buffer.write('\x1b[0m');
  return buffer.toString();
}

class _Measured {
  const _Measured({
    required this.worstFrameLayouts,
    required this.deferredRuns,
    required this.cellLayouts,
    required this.cellsPainted,
    required this.runsPerFrame,
  });

  /// The most run paragraphs any one frame laid out.
  final int worstFrameLayouts;

  /// Runs painted cell by cell because the budget was spent.
  final int deferredRuns;

  /// Cell paragraphs laid out across the whole run.
  final int cellLayouts;

  final int cellsPainted;

  /// How many style runs a frame of this content actually contains — what an
  /// unbudgeted painter would lay out on the frame the content arrives.
  final int runsPerFrame;
}

/// A viewport being filled with a screenful of brand new output every frame:
/// the shape of an agent CLI printing a build log, and the case that drops
/// frames.
class _StreamedViewport {
  _StreamedViewport({required this.colored});

  final bool colored;

  _Measured run({required int frames}) {
    final terminal = Terminal(maxLines: kPerfRows * 4);
    terminal.resize(kPerfColumns, kPerfRows);
    final painter = makePainter();

    var worst = 0;
    var deferred = 0;
    var runsPerFrame = 0;

    for (var frame = 0; frame < frames; frame++) {
      for (var row = 0; row < kPerfRows; row++) {
        final n = frame * kPerfRows + row;
        terminal.write(
          colored
              ? '${_coloredLine(n, kPerfColumns)}\r\n'
              : '${'line $n'.padRight(kPerfColumns)}\r\n',
        );
      }
      if (frame == 0) {
        // How many runs this content is worth, measured on a throwaway painter
        // that is handed a fresh budget for every line so nothing is deferred.
        runsPerFrame = _countRuns(terminal, painter.cellSize.height);
      }
      painter.resetPaintCounters();
      final recorder = PictureRecorder();
      _paintBottom(painter, Canvas(recorder), terminal);
      recorder.endRecording().dispose();
      if (painter.runParagraphsLaidOut > worst) {
        worst = painter.runParagraphsLaidOut;
      }
      deferred += painter.runsDeferredToCells;
    }

    // Cell layouts are cumulative across the whole run, so they are read from a
    // painter that was never reset between frames.
    final cellPainter = makePainter()..resetPaintCounters();
    final replay = Terminal(maxLines: kPerfRows * 4);
    replay.resize(kPerfColumns, kPerfRows);
    for (var frame = 0; frame < frames; frame++) {
      for (var row = 0; row < kPerfRows; row++) {
        final n = frame * kPerfRows + row;
        replay.write(
          colored
              ? '${_coloredLine(n, kPerfColumns)}\r\n'
              : '${'line $n'.padRight(kPerfColumns)}\r\n',
        );
      }
      final recorder = PictureRecorder();
      _paintBottom(cellPainter, Canvas(recorder), replay);
      recorder.endRecording().dispose();
    }

    return _Measured(
      worstFrameLayouts: worst,
      deferredRuns: deferred,
      cellLayouts: cellPainter.cellParagraphsLaidOut,
      cellsPainted: frames * kPerfRows * kPerfColumns,
      runsPerFrame: runsPerFrame,
    );
  }

  /// Paints the last [kPerfRows] lines, the way `RenderTerminal` paints a
  /// viewport pinned to the bottom of the buffer.
  void _paintBottom(TerminalPainter painter, Canvas canvas, Terminal terminal) {
    painter.beginFrame();
    final lines = terminal.buffer.lines;
    final height = painter.cellSize.height;
    final first = lines.length - kPerfRows < 0 ? 0 : lines.length - kPerfRows;
    for (var i = first; i < lines.length; i++) {
      painter.paintLine(canvas, Offset(0, (i - first) * height), lines[i]);
    }
  }

  /// The number of multi-cell style runs on the visible lines, counted by
  /// giving a throwaway painter a fresh budget before every single line so the
  /// fallback never engages.
  int _countRuns(Terminal terminal, double height) {
    final painter = makePainter()..resetPaintCounters();
    final lines = terminal.buffer.lines;
    final first = lines.length - kPerfRows < 0 ? 0 : lines.length - kPerfRows;
    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    for (var i = first; i < lines.length; i++) {
      painter.beginFrame();
      painter.paintLine(canvas, Offset(0, (i - first) * height), lines[i]);
    }
    recorder.endRecording().dispose();
    return painter.runParagraphsLaidOut;
  }
}
