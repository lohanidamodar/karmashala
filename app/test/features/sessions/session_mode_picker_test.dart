import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/presentation/picker_face.dart';
import 'package:karmashala/src/features/sessions/application/session_modes_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/session_mode_picker.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

/// **The agent's own modes, in the session bar** (ACP design, C5): drawn only
/// once the agent has announced some, set through `sessions.setMode`, and a
/// refusal is said rather than swallowed.
void main() {
  late FakeDataServer server;
  late ProviderContainer container;

  const offered = SessionModesChanged(
    sessionId: 's1',
    currentModeId: 'default',
    availableModes: [
      SessionModeOption(id: 'default', name: 'Default'),
      SessionModeOption(
        id: 'plan',
        name: 'Plan',
        description: 'Reads and proposes; edits nothing.',
      ),
    ],
  );

  setUp(() async {
    final db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(
      agentInstallation(agentId: AgentIds.claudeAcp),
    );
    db.server.sessionRows.insert(session(agentInstallationId: 'a1'));
    container = ProviderContainer(overrides: [await server.override()]);
    addTearDown(container.dispose);
  });

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(1200, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: Row(children: [SessionModePicker(sessionId: 's1')]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('nothing until the agent announces modes; then the current one', (
    tester,
  ) async {
    await pump(tester);
    expect(find.byType(PickerFace), findsNothing);

    server.writeAsAnotherClient([offered]);
    await tester.pumpAndSettle();

    expect(find.byType(PickerFace), findsOneWidget);
    expect(find.text('Default'), findsOneWidget);
    expect(container.read(sessionModesProvider('s1'))?.current?.id, 'default');
  });

  testWidgets('lists every mode by name and sets the one chosen', (
    tester,
  ) async {
    await pump(tester);
    server.writeAsAnotherClient([offered]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Default'));
    await tester.pumpAndSettle();
    expect(find.text('Plan'), findsOneWidget);
    expect(find.text('Reads and proposes; edits nothing.'), findsOneWidget);

    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();

    expect(server.requests, contains('sessions.setMode'));
    // The server told the change back, and the face follows it.
    expect(find.text('Plan'), findsOneWidget);
    expect(find.text('Default'), findsNothing);
    expect(container.read(sessionModesProvider('s1'))?.current?.id, 'plan');
  });

  testWidgets('a refusal is shown in the server\'s words', (tester) async {
    await pump(tester);
    server.writeAsAnotherClient([offered]);
    await tester.pumpAndSettle();
    server.modeRefusal = 'This session has no modes to set.';

    await tester.tap(find.text('Default'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('This session has no modes to set.'), findsOneWidget);
    // Nothing moved: the face still names the mode the agent is in.
    expect(find.text('Default'), findsOneWidget);
  });

  testWidgets('fits a phone', (tester) async {
    await pump(tester, size: const Size(390, 844));
    server.writeAsAnotherClient([offered]);
    await tester.pumpAndSettle();

    expect(find.byType(PickerFace), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
