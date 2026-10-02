import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/presentation/picker_face.dart';
import 'package:karmashala/src/features/sessions/application/session_config_options_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/session_config_option_picker.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

/// **The agent's own config options, in the session bar** (ACP design, C5):
/// a picker per `select` option once the agent has announced them, the
/// `model` one first, set through `sessions.setConfigOption`; a refusal is
/// said rather than swallowed.
void main() {
  late FakeDataServer server;
  late ProviderContainer container;

  const announced = SessionConfigOptionsChanged(
    sessionId: 's1',
    options: [
      SessionConfigOption(
        id: 'thinking',
        name: 'Extended thinking',
        type: 'boolean',
        currentValue: false,
      ),
      // The session's mode again, as some agents also announce it: the mode
      // picker stands for it, so no second chip.
      SessionConfigOption(
        id: 'mode',
        name: 'Mode',
        type: 'select',
        category: 'mode',
        currentValue: 'agent',
        choices: [
          SessionConfigChoice(value: 'agent', name: 'Agent'),
          SessionConfigChoice(value: 'plan', name: 'Plan'),
        ],
      ),
      SessionConfigOption(
        id: 'effort',
        name: 'Effort',
        type: 'select',
        currentValue: 'medium',
        choices: [
          SessionConfigChoice(value: 'low', name: 'Low'),
          SessionConfigChoice(value: 'medium', name: 'Medium'),
        ],
      ),
      SessionConfigOption(
        id: 'model',
        name: 'Model',
        type: 'select',
        currentValue: 'claude-sonnet-5',
        choices: [
          SessionConfigChoice(
            value: 'claude-sonnet-5',
            name: 'Claude Sonnet 5',
            description: 'Fast and capable.',
          ),
          SessionConfigChoice(
            value: 'gpt-6',
            name: 'GPT-6',
            group: 'Other providers',
          ),
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
            body: Row(children: [SessionConfigPickers(sessionId: 's1')]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('only selects with choices are drawn, the model first', () {
    final drawn = SessionConfigPickers.selectable(announced);
    expect(drawn.map((o) => o.id), ['model', 'effort']);
    expect(SessionConfigPickers.selectable(null), isEmpty);
  });

  testWidgets('nothing until the agent announces options; then a picker per '
      'select, the model first, each naming its current choice', (
    tester,
  ) async {
    await pump(tester);
    expect(find.byType(PickerFace), findsNothing);

    server.writeAsAnotherClient([announced]);
    await tester.pumpAndSettle();

    expect(find.byType(PickerFace), findsNWidgets(2));
    expect(find.text('Claude Sonnet 5'), findsOneWidget);
    expect(find.text('Medium'), findsOneWidget);
    expect(find.text('Extended thinking'), findsNothing);
    final faces = tester
        .widgetList<PickerFace>(find.byType(PickerFace))
        .toList();
    expect(faces.first.label, 'Claude Sonnet 5');
    expect(
      container.read(sessionConfigOptionsProvider('s1'))?.option('model')?.id,
      'model',
    );
  });

  testWidgets('lists every choice by name under its group and sets the one '
      'chosen', (tester) async {
    await pump(tester);
    server.writeAsAnotherClient([announced]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Claude Sonnet 5'));
    await tester.pumpAndSettle();
    expect(find.text('GPT-6'), findsOneWidget);
    // A menu header is drawn in capitals.
    expect(find.text('OTHER PROVIDERS'), findsOneWidget);
    expect(find.text('Fast and capable.'), findsOneWidget);

    await tester.tap(find.text('GPT-6'));
    await tester.pumpAndSettle();

    expect(server.requests, contains('sessions.setConfigOption'));
    // The server told the change back, and the face follows it.
    expect(find.text('GPT-6'), findsOneWidget);
    expect(find.text('Claude Sonnet 5'), findsNothing);
    expect(
      container
          .read(sessionConfigOptionsProvider('s1'))
          ?.option('model')
          ?.currentValue,
      'gpt-6',
    );
  });

  testWidgets('a refusal is shown in the server\'s words', (tester) async {
    await pump(tester);
    server.writeAsAnotherClient([announced]);
    await tester.pumpAndSettle();
    server.configOptionRefusal = 'The agent refused the option: busy.';

    await tester.tap(find.text('Medium'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Low'));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('The agent refused the option: busy.'), findsOneWidget);
    // Nothing moved: the face still names the value the agent holds.
    expect(find.text('Medium'), findsOneWidget);
  });

  testWidgets('a value the agent holds that it did not list is shown as is', (
    tester,
  ) async {
    await pump(tester);
    server.writeAsAnotherClient([
      const SessionConfigOptionsChanged(
        sessionId: 's1',
        options: [
          SessionConfigOption(
            id: 'model',
            name: 'Model',
            type: 'select',
            currentValue: 'custom-model',
            choices: [SessionConfigChoice(value: 'a', name: 'A')],
          ),
        ],
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('custom-model'), findsOneWidget);
  });

  testWidgets('fits a phone', (tester) async {
    await pump(tester, size: const Size(390, 844));
    server.writeAsAnotherClient([announced]);
    await tester.pumpAndSettle();

    expect(find.byType(PickerFace), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
