import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/app/shell/side_panel.dart';
import 'package:karmashala/src/app/shell/side_panel_state.dart';
import 'package:karmashala/src/features/media/presentation/session_media_panel.dart';

import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';
import '../../support/fake_data_server.dart';
import 'package:agent_cli/process.dart';
import '../../support/test_machine.dart';

/// The Media surface, as the rail actually offers it.
///
/// The list itself is tested next door; what this pins is that the surface is
/// reachable at all — the complaint that started this work was that a pasted
/// picture was *nowhere*, and a panel behind a glyph nobody can find would be
/// the same complaint again.
void main() {
  late TestMachine db;
  late FakeDataServer server;

  setUp(() {
    db = TestMachine();
    server = FakeDataServer()
      ..environmentRows.upsert(localHostEnvironment(testTime));
  });

  Future<ProviderContainer> pumpApp(WidgetTester tester) async {
    final container = fakeTerminalContainer(
      machine: db,
      data: await server.override(),
    );
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const KarmashalaApp(),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  test('Media is offered on the rail like any other surface', () {
    expect(
      SidePanelSurface.offered(debugMode: false),
      contains(SidePanelSurface.media),
    );
    // Not scoped to a checkout: it describes the *session* on screen, so the
    // repository context line above the scoped surfaces would be answering a
    // question nobody asked here.
    expect(SidePanelSurface.media.scopedToRepository, isFalse);
    expect(SidePanel.iconFor(SidePanelSurface.media).fontPackage, 'picons');
  });

  testWidgets('the rail opens the media panel', (tester) async {
    final container = await pumpApp(tester);

    await tester.tap(find.bySemanticsLabel(SidePanelSurface.media.label));
    await tester.pumpAndSettle();

    expect(container.read(sidePanelProvider), SidePanelSurface.media);
    expect(find.byType(SessionMediaPanel), findsOneWidget);
    // With nothing on screen there is nothing to list, and the panel says which
    // question it is unable to answer rather than showing an empty box.
    expect(find.textContaining('Open a session'), findsOneWidget);
  });
}
