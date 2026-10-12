import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/window_matrix.dart';
import 'responsive_surfaces.dart';

/// The sizes the dashboard's session tree was designed at (round 92): two
/// phones, the width the queue moves beside the work, a laptop and a wide
/// desktop, each at 1x and Android's 1.6x text — with a sub-session open.
final _treeMatrix = [
  for (final size in [
    Size(360, 800),
    Size(390, 844),
    Size(840, 900),
    Size(1280, 900),
    Size(1920, 1080),
  ])
    for (final scale in [1.0, 1.6])
      WindowCell(
        '${size.width.toInt()}x${size.height.toInt()}'
        '${scale == 1 ? '' : ' @ ${scale}x text'}',
        size,
        textScale: scale,
      ),
];

void main() {
  testWidgets('the dashboard tree fits 360 to 1920 px at 1x and 1.6x text', (
    tester,
  ) async {
    final surface = responsiveSurfaces.singleWhere(
      (s) => s.name == 'dash-tree',
    );
    final build = await surface.prepare(tester, Brightness.dark);
    await expectSurvivesWindowMatrix(
      tester,
      build: build,
      warmUp: surface.warmUp,
      matrix: _treeMatrix,
      checkFocus: false,
      because: 'round 92: the session tree, phones to a wide desktop',
    );
    await tester.pump(const Duration(seconds: 30));
  });
}
