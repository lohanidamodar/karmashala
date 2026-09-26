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
///
/// The budgets below are counted on a **settled** viewport — see
/// [countDrawOps]. They used to be counted on a cold painter, which happened to
/// be the same number because the painter laid out every run it saw no matter
/// how many that was. It no longer does: a frame carrying a screenful of text
/// nobody has printed before spends 15.6 ms of a 16.7 ms budget laying
/// paragraphs out, so the painter now caps how many it lays out per frame and
/// draws the rest cell by cell (`TerminalPainter.beginFrame`). The batched
/// draw-call count is therefore reached a few frames after the content appears
/// rather than on its first frame, and the first frame is bounded separately —
/// by the per-cell painter's own count, asserted at the bottom of this file and
/// in `paint_layout_cost_test.dart`.
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

  /// The transient the budgets above deliberately do not cover. A frame whose
  /// content has never been painted before falls back to per-cell drawing for
  /// every run past the layout budget, so its draw-call count rises towards the
  /// per-cell painter's — but it must never *pass* it, because per-cell is
  /// exactly what the fallback does and one merged background rect per run is
  /// strictly fewer calls than one per cell.
  for (final corpus in PerfCorpus.values) {
    test('the first frame of $corpus never costs more than per-cell', () {
      final cold = countDrawOps(buildTerminal(corpus), settled: false);
      final perCell = countDrawOps(buildTerminal(corpus), perCell: true);
      // ignore: avoid_print
      print('first frame $corpus: $cold draw ops (per-cell $perCell)');
      expect(
        cold,
        lessThanOrEqualTo(perCell),
        reason:
            'the layout-budget fallback may cost more draw calls than a '
            'settled batched frame, but never more than the painter it falls '
            'back to',
      );
    });
  }

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
