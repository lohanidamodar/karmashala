import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/presentation/picker_face.dart';
import 'package:karmashala/src/features/sessions/presentation/session_mode_picker.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

/// **A mode the agent's spec places on a rung says what it allows**, and a
/// bypassing one is confirmed before it is set — Antigravity's shipped modes.
void main() {
  late FakeDataServer server;
  late ProviderContainer container;

  const offered = SessionModesChanged(
    sessionId: 's1',
    currentModeId: 'default',
    availableModes: [
      SessionModeOption(id: 'default', name: 'Default'),
      SessionModeOption(id: 'auto_edit', name: 'Auto Edit'),
      SessionModeOption(id: 'yolo', name: 'YOLO'),
    ],
  );

  setUp(() async {
    final db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(
      agentInstallation(agentId: AgentIds.antigravityAcp),
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
    server.writeAsAnotherClient([offered]);
    await tester.pumpAndSettle();
  }

  testWidgets('the face and each row name the rung', (tester) async {
    await pump(tester);
    expect(find.text('· Ask'), findsOneWidget);
    expect(tester.widget<PickerFace>(find.byType(PickerFace)).alarming, isFalse);

    await tester.tap(find.text('Default'));
    await tester.pumpAndSettle();
    expect(find.text('Accept edits'), findsOneWidget);
    expect(find.text('Bypass'), findsOneWidget);
  });

  testWidgets('a bypassing mode is confirmed: cancel sets nothing', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Default'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('YOLO'));
    await tester.pumpAndSettle();

    expect(find.text('YOLO?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(server.requests, isNot(contains('sessions.setMode')));
  });

  testWidgets('a bypassing mode confirmed is set, and the face warns', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Default'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('YOLO'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use YOLO'));
    await tester.pumpAndSettle();

    expect(server.requests, contains('sessions.setMode'));
    expect(tester.widget<PickerFace>(find.byType(PickerFace)).alarming, isTrue);
  });

  testWidgets('a quiet mode is set without asking', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Default'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Auto Edit'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(server.requests, contains('sessions.setMode'));
  });

  testWidgets('fits a phone', (tester) async {
    await pump(tester, size: const Size(390, 844));
    expect(find.byType(PickerFace), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
