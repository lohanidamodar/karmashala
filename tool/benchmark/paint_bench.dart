import 'package:flutter_test/flutter_test.dart';

import '../../test/terminal/perf/corpora.dart';
import '../../test/terminal/perf/paint_harness.dart';

/// Benchmark — NOT part of `flutter test`'s default run. It lives under `tool/`
/// so that discovery never picks it up. Run it on demand:
///
///   flutter test tool/benchmark/paint_bench.dart
///
/// Reports `paint()` wall time for a full 200x50 frame. Timings are printed,
/// not asserted: wall clock on a developer machine is too noisy to gate on, so
/// this cannot detect a regression on its own — read the numbers yourself, and
/// compare them against a run of the same build on the same machine.
///
/// The asserted budget lives in `test/terminal/perf/draw_ops_test.dart`, which
/// counts draw calls and is therefore machine-independent. That file and the
/// pixel goldens beside it are the CI guard; this one is a measuring stick.
void main() {
  test('paint() timing for a ${kPerfColumns}x$kPerfRows viewport', () {
    for (final corpus in PerfCorpus.values) {
      final terminal = buildTerminal(corpus);
      final perCell = benchPaint(terminal, perCell: true);
      final batched = benchPaint(terminal);
      // ignore: avoid_print
      print(
        '$corpus\n'
        '  per-cell median=${perCell.median.inMicroseconds}us '
        'p95=${perCell.p95.inMicroseconds}us\n'
        '  batched  median=${batched.median.inMicroseconds}us '
        'p95=${batched.p95.inMicroseconds}us',
      );
      expect(perCell.p95.inMicroseconds, greaterThan(0));
      expect(batched.p95.inMicroseconds, greaterThan(0));
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
