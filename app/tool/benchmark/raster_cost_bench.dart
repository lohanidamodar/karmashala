import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import '../../test/terminal/perf/corpora.dart';
import '../../test/terminal/perf/paint_harness.dart';

/// Benchmark — NOT part of `flutter test`.
///
///   flutter test tool/benchmark/raster_cost_bench.dart
///
/// The per-cell fallback in `TerminalPainter` trades UI-thread paragraph layout
/// for more draw calls in the display list. This measures the other side of
/// that trade: how long the *raster* side takes to turn each recording into
/// pixels, batched versus per-cell.
void main() {
  for (final corpus in PerfCorpus.values) {
    testWidgets('raster cost of $corpus', (tester) async {
      await tester.runAsync(() async {
        final terminal = buildTerminal(corpus);
        final painter = makePainter();
        final width = (painter.cellSize.width * kPerfColumns).ceil();
        final height = (painter.cellSize.height * kPerfRows).ceil();
        final bounds = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());

        Future<int> raster({required bool perCell}) async {
          // Warm both the paragraph caches and the GPU/CPU raster path.
          for (var i = 0; i < 3; i++) {
            final r = PictureRecorder();
            paintViewport(
              painter,
              Canvas(r, bounds),
              terminal,
              perCell: perCell,
            );
            final p = r.endRecording();
            (await p.toImage(width, height)).dispose();
            p.dispose();
          }
          final samples = <int>[];
          for (var i = 0; i < 10; i++) {
            final r = PictureRecorder();
            paintViewport(
              painter,
              Canvas(r, bounds),
              terminal,
              perCell: perCell,
            );
            final p = r.endRecording();
            final sw = Stopwatch()..start();
            final image = await p.toImage(width, height);
            sw.stop();
            samples.add(sw.elapsedMicroseconds);
            image.dispose();
            p.dispose();
          }
          samples.sort();
          return samples[samples.length ~/ 2];
        }

        final batched = await raster(perCell: false);
        final perCell = await raster(perCell: true);
        // ignore: avoid_print
        print('raster $corpus: batched=${batched}us perCell=${perCell}us');
      });
    }, timeout: const Timeout(Duration(minutes: 5)));
  }
}
