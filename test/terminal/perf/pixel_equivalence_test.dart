import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

import 'corpora.dart';
import 'paint_harness.dart';

/// Rasterises one full viewport, painted either per-cell or run-batched.
Future<ByteData> _raster(
  Terminal terminal, {
  required bool perCell,
  required int width,
  required int height,
}) async {
  final painter = makePainter();
  final bounds = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
  final recorder = PictureRecorder();
  final canvas = Canvas(recorder, bounds);
  // Opaque ground, so any difference shows up as a colour difference rather
  // than as alpha against an undefined background.
  canvas.drawRect(bounds, Paint()..color = const Color(0xFF000000));
  paintViewport(painter, canvas, terminal, perCell: perCell);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final bytes = await image.toByteData(format: ImageByteFormat.rawRgba);
  picture.dispose();
  image.dispose();
  return bytes!;
}

/// The hard correctness gate for the run-batched painter: it must draw exactly
/// what the original one-call-per-cell painter draws, for every corpus.
void main() {
  for (final corpus in PerfCorpus.values) {
    testWidgets('$corpus: batched paintLine is pixel-identical to per-cell', (
      tester,
    ) async {
      // Picture.toImage is completed by the engine, so it has to run outside
      // the widget tester's fake-async zone.
      await tester.runAsync(() => _compare(corpus));
    });
  }

  testWidgets('edge cases: batched paintLine is pixel-identical to per-cell', (
    tester,
  ) async {
    await tester.runAsync(
      () => _compareTerminal(
        buildEdgeCaseTerminal(),
        label: 'edge cases',
        columns: 40,
        rows: 12,
      ),
    );
  });
}

Future<void> _compare(PerfCorpus corpus) =>
    _compareTerminal(buildTerminal(corpus), label: '$corpus');

Future<void> _compareTerminal(
  Terminal terminal, {
  required String label,
  int columns = kPerfColumns,
  int rows = kPerfRows,
}) async {
  final painter = makePainter();
  final width = (painter.cellSize.width * columns).ceil();
  final height = (painter.cellSize.height * rows).ceil();

  final expected = await _raster(
    terminal,
    perCell: true,
    width: width,
    height: height,
  );
  final actual = await _raster(
    terminal,
    perCell: false,
    width: width,
    height: height,
  );

  expect(actual.lengthInBytes, expected.lengthInBytes);
  final a = actual.buffer.asUint8List();
  final b = expected.buffer.asUint8List();
  var firstDiff = -1;
  var diffCount = 0;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      if (firstDiff < 0) firstDiff = i;
      diffCount++;
    }
  }
  expect(
    diffCount,
    0,
    reason:
        '$label: batched painting differs from per-cell painting in '
        '$diffCount of '
        '${a.length} bytes (first at byte $firstDiff, pixel '
        '${firstDiff ~/ 4}, x=${(firstDiff ~/ 4) % width}, '
        'y=${(firstDiff ~/ 4) ~/ width}). The batching is wrong — fix the '
        'painter, do not relax this test.',
  );
}
