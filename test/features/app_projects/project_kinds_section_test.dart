import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/app_projects/presentation/project_kinds_section.dart';

import '../../support/window_matrix.dart';

Widget _page() => const MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: ProjectKindsSection())),
);

void main() {
  testWidgets('every kind is on the page, whether or not it can be built', (
    tester,
  ) async {
    await tester.pumpWidget(_page());
    expect(find.text('Flutter'), findsOneWidget);
    expect(find.text('Native Android'), findsOneWidget);
    expect(find.text('Native iOS'), findsOneWidget);
    expect(find.text('React Native'), findsOneWidget);
  });

  testWidgets('a measured build shows the command and where it lands', (
    tester,
  ) async {
    await tester.pumpWidget(_page());
    expect(
      find.textContaining('build apk --debug'),
      findsOneWidget,
      reason: 'the Flutter row shows what would actually run',
    );
    expect(
      find.textContaining('<module>/build/outputs/apk/debug'),
      findsOneWidget,
      reason:
          'and the native Android row shows its own artifact, with the module '
          'left as the placeholder detection fills in',
    );
  });

  testWidgets(
    'a target nobody ran shows its reason where the command would be',
    (tester) async {
      await tester.pumpWidget(_page());
      // The whole point of the page: written out in full, and refusing.
      expect(find.textContaining('needs a Mac'), findsWidgets);
      expect(
        find.textContaining('release-build.yml has no macOS job'),
        findsWidgets,
      );
      // And a known absence reads differently from a blind spot.
      expect(find.textContaining('no live debug channel'), findsWidgets);
      // The shape is readable, and marked as a shape rather than as a reading.
      expect(
        find.textContaining('Would be: xcodebuild -scheme'),
        findsOneWidget,
      );
      // And React Native refuses with the count that was actually taken.
      expect(
        find.textContaining('no React Native or Expo project on this machine'),
        findsWidgets,
      );
      expect(find.textContaining('six package.json files'), findsWidgets);
    },
  );

  testWidgets('a kind that cannot build says so beside its name', (
    tester,
  ) async {
    await tester.pumpWidget(_page());
    // iOS and React Native, and nothing else: the two nobody has run.
    expect(find.text('detection only'), findsNWidgets(2));
  });

  testWidgets('survives the window matrix', (tester) async {
    await expectSurvivesWindowMatrix(
      tester,
      build: _page,
      // Nothing here is focusable or pressable: the section is a statement of
      // what the tool will and will not do, and offers no button at all.
      checkFocus: false,
      checkSemantics: false,
    );
  });

  testWidgets('fits a phone, where the Tools page draws it in one column', (
    tester,
  ) async {
    await expectSurvivesWindowMatrix(
      tester,
      build: _page,
      matrix: const [
        WindowCell('390x844 (phone width)', Size(390, 844)),
        WindowCell('390x844 @ 1.3x', Size(390, 844), textScale: 1.3),
        WindowCell('390x844 @ 2x', Size(390, 844), textScale: 2),
      ],
      checkFocus: false,
      checkSemantics: false,
      because:
          'a kind name and "detection only" shared a row that could not '
          'give way',
    );
  });
}
