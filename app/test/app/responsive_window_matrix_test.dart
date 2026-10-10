import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/window_matrix.dart';
import 'responsive_surfaces.dart';

/// **Everything recent is responsive** (owner, 2026-10-10): the Agent
/// dashboard, Stores, Usage, Pipelines, the settings rounds 79–84 added and
/// the phone shell, each from a 360 px phone to a 1440 px desktop at 1x and
/// 1.6x text. Overflow anywhere in that range fails here, as does a button
/// with no name.
void main() {
  for (final surface in responsiveSurfaces) {
    testWidgets('${surface.name} fits every window from 360 to 1440 px', (
      tester,
    ) async {
      final build = await surface.prepare(tester, Brightness.light);
      await expectSurvivesWindowMatrix(
        tester,
        build: build,
        warmUp: surface.warmUp,
        matrix: [
          for (final cell in phoneToDesktopMatrix)
            if (!(surface.phoneOnly && cell.size.width >= 600) &&
                !(surface.desktopOnly && cell.size.width < 600))
              cell,
        ],
        // Tab order is the shared matrices' job at the minimum window; here
        // the question is fit, at twelve sizes.
        checkFocus: false,
        because: 'round 85: phones to a wide desktop, at 1x and 1.6x text',
      );
      // The board's timers end with it, and a read that failed (no agent
      // registry offline) stops retrying once nothing watches it.
      await tester.pump(const Duration(seconds: 30));
    });
  }
}
