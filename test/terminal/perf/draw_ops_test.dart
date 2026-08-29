import 'package:flutter_test/flutter_test.dart';

import 'corpora.dart';
import 'paint_harness.dart';

void main() {
  test('baseline: per-cell draw ops for a 200x50 viewport', () {
    for (final corpus in PerfCorpus.values) {
      final ops = countDrawOps(buildTerminal(corpus), perCell: true);
      // ignore: avoid_print
      print('per-cell  $corpus: $ops draw ops');
      expect(ops, greaterThan(0));
    }
  });
}
