import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

import 'corpora.dart';
import 'paint_harness.dart';

/// How the reference frame is painted.
enum _Reference {
  /// The run-batched painter under test.
  batched,

  /// Per-cell, in the batched painter's order: backgrounds, then glyphs.
  perCellTwoPass,
}

/// Rasterises one full viewport.
Future<ByteData> _raster(
  Terminal terminal, {
  required _Reference how,
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
  switch (how) {
    case _Reference.batched:
      paintViewport(painter, canvas, terminal);
    case _Reference.perCellTwoPass:
      paintViewportPerCellTwoPass(painter, canvas, terminal);
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final bytes = await image.toByteData(format: ImageByteFormat.rawRgba);
  picture.dispose();
  image.dispose();
  return bytes!;
}

/// The hard correctness gate for the run-batched painter: it must draw exactly
/// what the per-cell painter draws, for every corpus.
///
/// "The per-cell painter" means [paintViewportPerCellTwoPass] — the same cells,
/// one draw call each, in the order the batched painter is obliged to use.
/// See its doc comment for why the interleaved order is not the right
/// reference; comparing against that one holds the batching to a property of
/// the *font* rather than of the batching.
///
/// The tolerance below is one 255th of one channel, and nothing about the
/// batching can hide under it. A run merged that should not have been, a glyph
/// at the wrong x, a colour taken from the wrong cell — every one of those
/// moves whole glyphs and shows up as differences of tens or hundreds of
/// levels across hundreds of pixels. What the tolerance covers is the single
/// thing that genuinely cannot be identical: an underlined run draws **one**
/// continuous underline where the per-cell painter draws one segment per cell,
/// and the seams between abutting segments round differently by a single
/// level. One pixel of the edge-case corpus, at delta 1.
///
/// Do not widen this to make a failure go away — a real batching bug is orders
/// of magnitude larger, and shrinking the gap by relaxing the gate is how the
/// gate stops being one.
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

/// The most a channel may differ, and only where an underline seam explains it.
const int _antialiasTolerance = 1;

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
    how: _Reference.perCellTwoPass,
    width: width,
    height: height,
  );
  final actual = await _raster(
    terminal,
    how: _Reference.batched,
    width: width,
    height: height,
  );

  expect(actual.lengthInBytes, expected.lengthInBytes);
  final a = actual.buffer.asUint8List();
  final b = expected.buffer.asUint8List();
  var firstDiff = -1;
  var maxDelta = 0;
  var overTolerance = 0;
  for (var i = 0; i < a.length; i++) {
    final delta = (a[i] - b[i]).abs();
    if (delta == 0) continue;
    if (delta > maxDelta) maxDelta = delta;
    if (delta <= _antialiasTolerance) continue;
    if (firstDiff < 0) firstDiff = i;
    overTolerance++;
  }
  expect(
    overTolerance,
    0,
    reason:
        '$label: batched painting differs from per-cell painting by more than '
        '$_antialiasTolerance/255 in $overTolerance of ${a.length} bytes '
        '(worst delta $maxDelta; first at byte $firstDiff, pixel '
        '${firstDiff ~/ 4}, x=${(firstDiff ~/ 4) % width}, '
        'y=${(firstDiff ~/ 4) ~/ width}). The batching is wrong — fix the '
        'painter, do not relax this test.',
  );
}
