import 'package:flutter_test/flutter_test.dart';

import 'corpora.dart';
import 'paint_harness.dart';

/// Per-corpus draw-op budgets for one full ${kPerfColumns}x$kPerfRows frame.
///
/// The floor for any painter is one draw call per *style run*, which is a
/// property of the content, not of the painter — so the budget is per corpus
/// rather than one global number. See
/// the design note §3.
const _budgets = <PerfCorpus, int>{
  // One background run and one text run per line is the floor; the budget is
  // the design's <800.
  PerfCorpus.plainLog: 800,
  // ~15 `ls` entries per line, each a coloured name plus a default-styled
  // separator, is ~31 irreducible style runs per line = ~1550 for 50 lines.
  // 800 is unreachable for this content with any painter.
  PerfCorpus.colorizedLs: 2000,
  // Gauge bars collapse to a handful of runs per line.
  PerfCorpus.tuiFrame: 800,
};

/// Draw-op counts are exact and machine-independent, which is what makes them
/// safe to assert on. Wall-clock numbers live in
/// `tool/benchmark/paint_bench.dart` and are only reported.
void main() {
  test('baseline: per-cell draw ops for one frame', () {
    for (final corpus in PerfCorpus.values) {
      final ops = countDrawOps(buildTerminal(corpus), perCell: true);
      // ignore: avoid_print
      print('per-cell  $corpus: $ops draw ops');
      expect(ops, greaterThan(0));
    }
  });

  _budgets.forEach((corpus, budget) {
    test('batched painting of $corpus stays under $budget draw ops', () {
      final ops = countDrawOps(buildTerminal(corpus));
      // ignore: avoid_print
      print('batched   $corpus: $ops draw ops');
      expect(
        ops,
        lessThan(budget),
        reason:
            '$corpus needs $ops draw ops for a ${kPerfColumns}x$kPerfRows '
            'frame (budget $budget)',
      );
    });
  });

  test('the adversarial corpus does not regress versus per-cell', () {
    final perCell = countDrawOps(
      buildTerminal(PerfCorpus.adversarial),
      perCell: true,
    );
    final batched = countDrawOps(buildTerminal(PerfCorpus.adversarial));
    // ignore: avoid_print
    print('adversarial: per-cell=$perCell batched=$batched draw ops');
    expect(
      batched,
      lessThanOrEqualTo(perCell),
      reason: 'batching may fail to help, but it must never cost more calls',
    );
  });
}
