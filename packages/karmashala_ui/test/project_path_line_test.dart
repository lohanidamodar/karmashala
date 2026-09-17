import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import 'support/layout_probe.dart';

/// Line two of a project: the environment badge, a missing-folder mark and the
/// path. `ProjectCard` drew it privately and the phone's project screen copied
/// it, so it is public for the copy to use.
void main() {
  const path = '/home/someone/src/popupbits/projects/karmashala-app/app';
  const badge = 'SSH: build-server-eu-west-1.internal.example.com';

  for (final density in UiDensity.values) {
    for (final width in [160.0, 240.0, 390.0]) {
      for (final scale in sweepScales) {
        testWidgets('fits ${width.toInt()}px at ${scale}x, ${density.name}', (
          tester,
        ) async {
          final overflows = await pumpInBox(
            tester,
            width: width,
            textScale: scale,
            density: density,
            child: const ProjectPathLine(
              path: path,
              missing: true,
              environmentBadge: badge,
            ),
          );
          expect(overflows, isEmpty);
        });
      }
    }
  }

  testWidgets('the badge takes half the line at most, the path the rest', (
    tester,
  ) async {
    await pumpInBox(
      tester,
      width: 300,
      child: const ProjectPathLine(path: path, environmentBadge: badge),
    );
    expect(tester.getSize(find.text(badge)).width, lessThanOrEqualTo(150));
    expect(find.text(path), findsOneWidget);
    expect(find.byIcon(AppIcons.warningCircle), findsNothing);
  });

  testWidgets('a missing folder is said where the path was, in the error ink', (
    tester,
  ) async {
    await pumpInBox(
      tester,
      width: 400,
      child: const ProjectPathLine(path: '/w/app', missing: true),
    );
    const said = 'Folder not found — /w/app';
    expect(find.text(said), findsOneWidget);
    expect(find.byIcon(AppIcons.warningCircle), findsOneWidget);
    final scheme = Theme.of(tester.element(find.text(said))).colorScheme;
    expect(tester.widget<Text>(find.text(said)).style?.color, scheme.error);
  });

  testWidgets('a missing folder with no recorded path still says so', (
    tester,
  ) async {
    await pumpInBox(
      tester,
      width: 400,
      child: const ProjectPathLine(path: '', missing: true),
    );
    expect(find.text('Folder not found'), findsOneWidget);
  });

  testWidgets('ProjectCard draws its path with it', (tester) async {
    // Under a thumb. A pointer row keeps one line and puts the path and the
    // badge in the name's tooltip, drawing the line only for a missing folder.
    await pumpInBox(
      tester,
      width: 400,
      density: UiDensity.touch,
      child: ProjectCard(
        name: 'app',
        path: '/w/app',
        expanded: false,
        selected: false,
        environmentBadge: 'WSL: Ubuntu',
        summary: const ProjectSummary(sessions: 1),
        onTap: () {},
        menuItemsBuilder: () => const [],
        onMenu: (_) {},
      ),
    );
    expect(
      find.descendant(
        of: find.byType(ProjectPathLine),
        matching: find.text('/w/app'),
      ),
      findsOneWidget,
    );
  });
}
