import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/presentation/picker_face.dart';
import 'package:karmashala/src/features/sessions/presentation/model_chip.dart';
import 'package:karmashala/src/features/sessions/presentation/permission_mode_chip.dart';
import 'package:karmashala/src/features/sessions/presentation/session_mode_picker.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

/// **An ACP session's status bar**: the PTY permission and
/// model chips stand down — the agent's mode is its permission axis and its
/// model is a config option — and the agent's own pickers take their place.
/// Decided by the adapter's capability, never by the agent's id.
void main() {
  late FakeDataServer server;
  late ProviderContainer container;

  const modes = SessionModesChanged(
    sessionId: 's1',
    currentModeId: 'agent',
    availableModes: [
      SessionModeOption(id: 'agent', name: 'Agent'),
      SessionModeOption(id: 'plan', name: 'Plan'),
    ],
  );
  const options = SessionConfigOptionsChanged(
    sessionId: 's1',
    options: [
      SessionConfigOption(
        id: 'model',
        name: 'Model',
        type: 'select',
        currentValue: 'claude-sonnet-5',
        choices: [
          SessionConfigChoice(
            value: 'claude-sonnet-5',
            name: 'Claude Sonnet 5',
          ),
          SessionConfigChoice(value: 'gpt-6', name: 'GPT-6'),
        ],
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

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                PermissionModeChip(sessionId: 's1'),
                SessionModePicker(sessionId: 's1'),
                SessionModelChip(sessionId: 's1'),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the PTY permission and model chips draw nothing for an ACP '
      'session; the agent\'s mode and model pickers stand in their place', (
    tester,
  ) async {
    await pump(tester);
    expect(find.byType(PickerFace), findsNothing);

    server.writeAsAnotherClient([modes, options]);
    await tester.pumpAndSettle();

    final faces = tester
        .widgetList<PickerFace>(find.byType(PickerFace))
        .map((face) => face.label)
        .toList();
    expect(faces, ['Agent', 'Claude Sonnet 5']);
    expect(find.text('Follow the Settings default'), findsNothing);
  });

  testWidgets('a mode pick and a model pick each reach their own request', (
    tester,
  ) async {
    await pump(tester);
    server.writeAsAnotherClient([modes, options]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Agent'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    expect(server.requests, contains('sessions.setMode'));

    await tester.tap(find.text('Claude Sonnet 5'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('GPT-6'));
    await tester.pumpAndSettle();
    expect(server.requests, contains('sessions.setConfigOption'));

    final faces = tester
        .widgetList<PickerFace>(find.byType(PickerFace))
        .map((face) => face.label)
        .toList();
    expect(faces, ['Plan', 'GPT-6']);
  });
}
