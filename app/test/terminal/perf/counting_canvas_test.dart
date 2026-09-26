import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'corpora.dart';
import 'counting_canvas.dart';

void main() {
  test('counts draw calls and forwards them to the inner canvas', () {
    final recorder = PictureRecorder();
    final canvas = CountingCanvas(Canvas(recorder));

    canvas.drawRect(const Rect.fromLTWH(0, 0, 10, 10), Paint());
    canvas.drawRect(const Rect.fromLTWH(10, 0, 10, 10), Paint());
    canvas.save();
    canvas.restore();

    expect(canvas.counts['drawRect'], 2);
    expect(canvas.counts['save'], 1);
    expect(canvas.drawOps, 2, reason: 'save/restore are not draw ops');

    final picture = recorder.endRecording();
    expect(picture.approximateBytesUsed, greaterThan(0));
    picture.dispose();
  });

  test('reset clears the counters', () {
    final recorder = PictureRecorder();
    final canvas = CountingCanvas(Canvas(recorder))
      ..drawRect(Rect.zero, Paint())
      ..reset();
    expect(canvas.drawOps, 0);
    recorder.endRecording().dispose();
  });

  // `buildTerminal` defaults to these, so asserting a terminal's size against
  // them cannot fail. What can fail is the corpus being shrunk — which would
  // quietly make every budget in `draw_ops_test.dart` easier to meet — so the
  // viewport those budgets are stated against is pinned to its literal size
  // here instead.
  test('the perf viewport the budgets are stated against is 200x50', () {
    expect(kPerfColumns, 200);
    expect(kPerfRows, 50);
  });

  for (final corpus in PerfCorpus.values) {
    test('$corpus fills a ${kPerfColumns}x$kPerfRows buffer', () {
      final terminal = buildTerminal(corpus);
      expect(terminal.buffer.lines.length, greaterThanOrEqualTo(kPerfRows));
      // Every visible line has content — an empty corpus would make the
      // draw-op budget meaningless.
      for (var i = 0; i < kPerfRows; i++) {
        expect(
          terminal.buffer.lines[i].getTrimmedLength(kPerfColumns),
          greaterThan(0),
          reason: 'line $i of $corpus is empty',
        );
      }
    });
  }
}
