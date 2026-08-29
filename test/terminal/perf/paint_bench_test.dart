import 'package:flutter_test/flutter_test.dart';

import 'corpora.dart';
import 'paint_harness.dart';

/// Reports `paint()` wall time for a full 200x50 frame. Timings are printed,
/// not asserted: wall clock on a developer machine is too noisy to gate on.
/// The asserted budget lives in `draw_ops_test.dart`, which counts draw calls
/// and is therefore machine-independent.
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
