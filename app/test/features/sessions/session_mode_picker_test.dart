import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/presentation/picker_face.dart';
import 'package:karmashala/src/features/sessions/application/session_modes_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/session_mode_picker.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

/// **The agent's own modes, in the session bar**: drawn only
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
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(textScale),
            ),
            child: const Scaffold(
              body: Row(children: [SessionModePicker(sessionId: 's1')]),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  String? storedMode() =>
      container.read(sessionsDataProvider).getById('s1')?.permissionMode;

  List<String> faces(WidgetTester tester) => [
    for (final face in tester.widgetList<PickerFace>(find.byType(PickerFace)))
      face.label,
  ];

  testWidgets('before the agent announces modes, the one the session will '
      "start in, from the descriptor; then the agent's own", (tester) async {
    await pump(tester);
    expect(faces(tester), ['Ask every time']);

    server.writeAsAnotherClient([offered]);
    await tester.pumpAndSettle();

    expect(faces(tester), ['Default']);
    expect(container.read(sessionModesProvider('s1'))?.current?.id, 'default');
  });

  testWidgets("a pick before the start is the session's permission mode, "
      'which the start sends to the agent', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Ask every time'));
    await tester.pumpAndSettle();
    // Every mode the descriptor declares, auto among them.
    for (final label in [
      'Plan mode',
      "Don't ask",
      'Accept edits',
      'Automatic',
      'Bypass (full autonomy)',
    ]) {
      expect(find.text(label), findsWidgets, reason: label);
    }
    await tester.tap(find.text('Automatic').last);
    await tester.pumpAndSettle();

    expect(storedMode(), 'mode=auto');
    expect(faces(tester), ['Automatic']);

    // Back to following Settings.
    await tester.tap(find.text('Automatic'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Follow the Settings default'));
    await tester.pumpAndSettle();
    expect(storedMode(), isNull);
    expect(faces(tester), ['Ask every time']);
  });

  testWidgets('bypass before the start is confirmed; Cancel leaves the '
      'session as it was', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Ask every time'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bypass (full autonomy)'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(storedMode(), isNull);
    expect(faces(tester), ['Ask every time']);

    await tester.tap(find.text('Ask every time'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bypass (full autonomy)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use Bypass (full autonomy)'));
    await tester.pumpAndSettle();
    expect(storedMode(), 'mode=bypassPermissions');
    expect(faces(tester), ['Bypass (full autonomy)']);
  });

  testWidgets('the starting face fits a phone at text scale 1.6', (
    tester,
  ) async {
    await pump(tester, size: const Size(360, 740), textScale: 1.6);
    expect(faces(tester), ['Ask every time']);
    expect(tester.takeException(), isNull);
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

  testWidgets('a new list of modes the agent announces mid-session redraws '
      'the picker without a restart', (tester) async {
    await pump(tester);
    server.writeAsAnotherClient([offered]);
    await tester.pumpAndSettle();
    expect(faces(tester), ['Default']);

    server.writeAsAnotherClient([
      const SessionModesChanged(
        sessionId: 's1',
        currentModeId: 'review',
        availableModes: [
          SessionModeOption(id: 'default', name: 'Default'),
          SessionModeOption(id: 'review', name: 'Review'),
        ],
      ),
    ]);
    await tester.pumpAndSettle();
    expect(faces(tester), ['Review']);

    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    expect(find.text('Default'), findsOneWidget);
    expect(find.text('Plan'), findsNothing);
  });
}
