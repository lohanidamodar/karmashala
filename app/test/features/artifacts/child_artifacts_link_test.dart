import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/artifacts/presentation/artifact_count_badge.dart';
import 'package:karmashala/src/features/artifacts/presentation/artifacts_panel.dart';
import 'package:karmashala_ui/theme.dart';

import '../../support/fake_data_server.dart';
import 'artifacts_data_test.dart' show sampleArtifact;

/// In the subagents panel, a child session that showed artifacts says how
/// many, and opens them.
void main() {
  for (final size in const [Size(390, 844), Size(1440, 900)]) {
    testWidgets('a child\'s artifacts are one tap away at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final server = FakeDataServer();
      server.showArtifact(
        sampleArtifact(id: 'c-a', sessionId: 'child'),
        utf8.encode('<p>x</p>'),
      );
      server.showArtifact(
        sampleArtifact(id: 'c-b', sessionId: 'child'),
        utf8.encode('<p>y</p>'),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            await server.override(),
          ],
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: const Scaffold(
              body: Center(child: ChildArtifactsLink(sessionId: 'child')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2 artifacts'), findsOneWidget);

      await tester.tap(find.text('2 artifacts'));
      await tester.pumpAndSettle();
      expect(find.byType(SessionArtifactsView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a child that showed nothing takes no room', (tester) async {
    final server = FakeDataServer();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [await server.override()],
        child: const MaterialApp(
          home: Scaffold(body: ChildArtifactsLink(sessionId: 'child')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('artifact'), findsNothing);
  });
}
