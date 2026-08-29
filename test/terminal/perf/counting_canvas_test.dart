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

  for (final corpus in PerfCorpus.values) {
    test('$corpus fills a ${kPerfColumns}x$kPerfRows buffer', () {
      final terminal = buildTerminal(corpus);
      expect(terminal.viewWidth, kPerfColumns);
      expect(terminal.viewHeight, kPerfRows);
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
