import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/quick_open/quick_open.dart';
import 'package:karmashala/src/app/shell/side_panel_state.dart';
import 'package:karmashala/src/features/artifacts/data/artifacts_data.dart';
import 'package:karmashala/src/features/artifacts/presentation/artifact_card.dart';
import 'package:karmashala/src/features/explorer/application/session_context.dart';

import '../../support/fake_data_server.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';
import 'artifacts_data_test.dart' show sampleArtifact;

/// An artifact of the session on screen is one search away in quick open,
/// and choosing it opens it where its card would.
void main() {
  testWidgets('quick open finds an artifact and opens it in the side panel', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = FakeDataServer();
    server.showArtifact(sampleArtifact(), utf8.encode('<p>x</p>'));
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        ...fakeTerminalOverrides(machine: TestMachine()),
        panelSessionIdProvider.overrideWithValue('s1'),
      ],
    );
    addTearDown(container.dispose);
    await container.read(artifactsDataProvider).forSession('s1');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => QuickOpen.show(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Chart a1');
    await tester.pumpAndSettle();

    expect(find.textContaining('Artifact · HTML · revision 1'), findsOneWidget);
    await tester.tap(find.text('Chart a1').last);
    await tester.pumpAndSettle();

    expect(container.read(sidePanelProvider), SidePanelSurface.artifacts);
    expect(container.read(selectedArtifactProvider), 'a1');
  });
}
